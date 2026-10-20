import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Buttons

struct ExportButtons: View {
    let meeting: Meeting
    let activeTab: DetailTab
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    /// Latest meeting state — pick up alias renames without waiting for the
    /// parent view to hand us a fresh `meeting`.
    private var liveMeeting: Meeting {
        appState.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private var copyText: String {
        if activeTab == .summary {
            return liveMeeting.aliasedSummary ?? ""
        }
        return liveMeeting.aliasedTranscript ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                tomLog("User action: copied \(activeTab == .summary ? "summary" : "transcript") to clipboard (\(copyText.count) chars, meeting=\(liveMeeting.id.uuidString.prefix(8)))")
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text(copied ? "Copied!" : "Copy")
                        .font(.system(size: 11))
                }
                .foregroundColor(copied ? .green : .subtleText)
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)

            ExportMenuButton(meeting: liveMeeting, fontSize: 11)
        }
        .padding(.trailing, 4)
    }
}

// MARK: - Quick View Export Buttons (single-click panel)

struct QuickViewExportButtons: View {
    let meeting: Meeting
    let activeTab: QuickViewTab
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    private var liveMeeting: Meeting {
        appState.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private var copyText: String {
        if activeTab == .summary {
            return liveMeeting.aliasedSummary ?? ""
        }
        return liveMeeting.aliasedTranscript ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                tomLog("User action: copied \(activeTab == .summary ? "summary" : "transcript") to clipboard (\(copyText.count) chars, meeting=\(liveMeeting.id.uuidString.prefix(8)))")
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text(copied ? "Copied!" : "Copy")
                        .font(.system(size: 12))
                }
                .foregroundColor(copied ? .green : .subtleText)
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)

            ExportMenuButton(meeting: liveMeeting, fontSize: 12)
        }
        .padding(.trailing, 8)
    }
}

// MARK: - Export Menu

/// "Export" button that pops Markdown / Video / Audio. NSMenu rather than a
/// SwiftUI `Menu` so the plain label keeps its styling (see `MeetingMenuItem`).
struct ExportMenuButton: View {
    let meeting: Meeting
    let fontSize: CGFloat
    @EnvironmentObject var appState: AppState

    var body: some View {
        let exporting = appState.exportingMeetingIDs.contains(meeting.id)
        Button {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in exportMenuItems(for: meeting, appState: appState) {
                menu.addItem(item)
            }
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text(exporting ? "Exporting…" : "Export")
                    .font(.system(size: fontSize))
            }
            .foregroundColor(.subtleText)
        }
        .buttonStyle(.plain)
    }
}

/// Send to Claude / ChatGPT (Feedback), Spec Folder, Markdown / Video / Audio entries shared by the detail Export button and
/// the meeting card menu. The owning menu needs `autoenablesItems = false`.
@MainActor
func exportMenuItems(for meeting: Meeting, appState: AppState) -> [NSMenuItem] {
    let markdown = MeetingMenuItem(String(localized: "Markdown"), systemImage: "doc.text") {
        exportMarkdown(meeting)
    }
    let video = MeetingMenuItem(String(localized: "Video (.mp4)"), systemImage: "film") {
        appState.exportMedia(meeting, kind: .video)
    }
    video.isEnabled = appState.canExportMedia(meeting, kind: .video)
    let audio = MeetingMenuItem(String(localized: "Audio (.m4a)"), systemImage: "waveform") {
        appState.exportMedia(meeting, kind: .audio)
    }
    audio.isEnabled = appState.canExportMedia(meeting, kind: .audio)
    guard meeting.kind == .learning else { return [markdown, video, audio] }
    let ready = meeting.state == .completed && !appState.exportingMeetingIDs.contains(meeting.id)
    let assistants = AIHandoff.Target.allCases.map { target in
        let item = MeetingMenuItem(String(localized: "Send to \(target.name)"), systemImage: "sparkles") {
            appState.sendToAI(meeting, target: target)
        }
        item.isEnabled = ready
        return item
    }
    let spec = MeetingMenuItem(String(localized: "Spec Folder…"), systemImage: "folder") {
        appState.exportSpecFolder(meeting)
    }
    spec.isEnabled = ready
    return assistants + [.separator(), spec, markdown, video, audio]
}

@MainActor
func exportMarkdown(_ meeting: Meeting) {
    let dateStr = shortDateFormatter.string(from: meeting.date)
    let dur = formatDuration(meeting.duration)
    var md = "# \(meeting.title)\n**Date:** \(dateStr)  **Duration:** \(dur)\n\n"
    if let summary = meeting.aliasedSummary, !summary.isEmpty {
        md += "## Summary\n\(summary)\n\n"
    }
    if let transcript = meeting.aliasedTranscript, !transcript.isEmpty {
        md += "## Transcript\n\(transcript)\n"
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = meeting.exportFileName(ext: "md")
    tomLog("User action: Export markdown (meeting=\(meeting.id.uuidString.prefix(8)))")
    if panel.runModal() == .OK, let url = panel.url {
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            tomLog("Export markdown saved: \(url.lastPathComponent) (\(md.count) chars)")
        } catch {
            tomLog("Export markdown failed: \(error)")
        }
    } else {
        tomLog("Export markdown cancelled")
    }
}
