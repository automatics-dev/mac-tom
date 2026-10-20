import AppKit
import SwiftUI

/// Hands a Feedback session to Claude or ChatGPT: the review (annotations,
/// what was said, full transcript) as a Markdown file plus the annotated
/// screenshots go on the clipboard as files, and the assistant opens on a
/// new chat. One ⌘V attaches everything.
enum AIHandoff {

    enum Target: String, CaseIterable {
        case claude, chatGPT

        var name: String {
            switch self {
            case .claude:  return "Claude"
            case .chatGPT: return "ChatGPT"
            }
        }

        var bundleID: String {
            switch self {
            case .claude:  return "com.anthropic.claudefordesktop"
            case .chatGPT: return "com.openai.chat"
            }
        }

        /// New chat in the desktop app when it's installed, else the web.
        var appURL: URL? {
            switch self {
            case .claude:  return URL(string: "claude://claude.ai/new")
            case .chatGPT: return nil
            }
        }

        var webURL: URL {
            switch self {
            case .claude:  return URL(string: "https://claude.ai/new")!
            case .chatGPT: return URL(string: "https://chatgpt.com/")!
            }
        }

        /// Files one message accepts, the review file included.
        var fileLimit: Int {
            switch self {
            case .claude:  return 20
            case .chatGPT: return 10
            }
        }
    }

    struct Package: Equatable {
        /// Review file first, then screenshots in annotation order.
        let files: [URL]
        /// Short message that goes with the files.
        let message: String
        /// Annotations whose screenshots didn't fit the file limit.
        let omittedImages: Int
    }

    static let reviewFileName = "feedback.md"

    /// Writes the review and copies the screenshots into `folder` (replaced
    /// if it exists). Every annotation gets its marked-up screenshot; crops
    /// are added only when they all fit, then screenshots are dropped from
    /// the end. `recordings` is where annotation image paths resolve.
    static func build(
        title: String,
        date: Date,
        annotations: [Annotation],
        segments: [TranscriptSegment],
        recordings: URL,
        target: Target,
        into folder: URL
    ) throws -> Package {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let ordered = annotations.sorted { $0.startTime < $1.startTime }
        let budget = max(0, target.fileLimit - 1)
        let withCrops = ordered.count + ordered.filter { $0.cropPath != nil }.count <= budget
        let attached = Array(ordered.prefix(budget))

        var images: [URL] = []
        var names: [UUID: (full: String?, crop: String?)] = [:]
        for annotation in attached {
            let prefix = String(format: "%@-%02d", annotation.isMarker ? "marker" : "annotation", annotation.index)
            let full = "\(prefix).png"
            try fm.copyItem(at: recordings.appendingPathComponent(annotation.screenshotPath), to: folder.appendingPathComponent(full))
            images.append(folder.appendingPathComponent(full))
            var crop: String?
            if withCrops, let cropPath = annotation.cropPath {
                crop = "\(prefix)-detail.png"
                try fm.copyItem(at: recordings.appendingPathComponent(cropPath), to: folder.appendingPathComponent(crop!))
                images.append(folder.appendingPathComponent(crop!))
            }
            names[annotation.id] = (full, crop)
        }
        let omitted = ordered.count - attached.count

        var md = """
        I recorded this feedback while going through the app on screen. Please implement the changes it asks for, and ask me if something is ambiguous.

        Screenshots are attached under the file names shown below, with my marks drawn in orange; "-detail" files are close-ups. The full transcript is at the end.


        """
        if omitted > 0 {
            md += "_Screenshots for the last \(omitted) annotation(s) are not attached (\(target.name) accepts \(target.fileLimit) files per message)._\n\n"
        }
        md += LearningReview.markdown(
            title: title, date: date,
            blocks: LearningReview.blocks(annotations: ordered, segments: segments)
        ) { names[$0.id] ?? (nil, nil) }
        let transcript = LearningReview.transcript(segments)
        if !transcript.isEmpty { md += "\n## Full transcript\n\n\(transcript)\n" }

        let review = folder.appendingPathComponent(reviewFileName)
        try md.write(to: review, atomically: true, encoding: .utf8)

        let count = images.count
        let message = count == 0
            ? "Please implement the feedback in \(reviewFileName)."
            : "Please implement the feedback in \(reviewFileName); the \(count) screenshot\(count == 1 ? "" : "s") it refers to are attached."
        return Package(files: [review] + images, message: message, omittedImages: omitted)
    }

    /// Puts the message and the files on the general pasteboard.
    @MainActor
    static func copy(_ package: Package) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([package.message as NSString] + package.files.map { $0 as NSURL })
    }

    /// Brings up a new chat: the desktop app if installed, else the website.
    @MainActor
    static func open(_ target: Target) {
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(withBundleIdentifier: target.bundleID) {
            if let url = target.appURL {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        } else {
            workspace.open(target.webURL)
        }
    }
}

/// Floating note after a handoff, since the assistant is now in front:
/// what was copied, that ⌘V attaches it, and the files in Finder for
/// dragging in where pasting files isn't supported.
@MainActor
enum HandoffNotice {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ package: AIHandoff.Package, target: AIHandoff.Target) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let images = package.files.count - 1
        let copied = images > 0
            ? String(localized: "Copied the review and \(images) screenshots")
            : String(localized: "Copied the review")
        var detail = String(localized: "Press ⌘V in \(target.name) to attach everything, then send.")
        if package.omittedImages > 0 {
            detail += " " + String(localized: "\(package.omittedImages) screenshots didn't fit the file limit; use Export ▸ Spec Folder for all of them.")
        }
        let files = package.files
        let host = NSHostingView(rootView: NoticeView(title: copied, detail: detail, onShowFiles: {
            NSWorkspace.shared.activateFileViewerSelecting(files)
            hide()
        }, onClose: { hide() }))
        let size = host.fittingSize
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(
            x: (screen.visibleFrame.midX - size.width / 2).rounded(),
            y: screen.visibleFrame.maxY - size.height - 16,
            width: size.width, height: size.height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    static func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private struct NoticeView: View {
        let title: String
        let detail: String
        let onShowFiles: () -> Void
        let onClose: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15))
                    .foregroundColor(.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show files", action: onShowFiles)
                        .buttonStyle(.link)
                        .font(.system(size: 11.5, weight: .medium))
                        .help("Reveal them in Finder to drag into the chat")
                        .padding(.top, 2)
                }
                .frame(width: 280, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.subtleText)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.divider))
            )
        }
    }
}
