import ImageIO
import SwiftUI

// MARK: - Review Tab (Feedback sessions)

/// A Feedback session's annotations in time order, each with its screenshot
/// and the speech spoken while making it, and narration in between.
struct ReviewTabContent: View {
    let meeting: Meeting
    /// False when the host already scrolls (the separate meeting window).
    var scrolls = true
    @EnvironmentObject private var appState: AppState
    @State private var blocks: [LearningReview.Block] = []
    /// Downsampled card images, decoded off the main thread.
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !loaded {
                Spacer()
            } else if blocks.isEmpty {
                Spacer()
                Text("No annotations in this session. Press ⌥A while recording to annotate the screen.")
                    .font(.system(size: 13))
                    .foregroundColor(.subtleText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                Spacer()
            } else if scrolls {
                ScrollView { list }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Reload when processing finishes (speech lands) or the user
        // switches meetings.
        .task(id: "\(meeting.id)-\(meeting.state.rawValue)") { await load() }
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if meeting.state != .completed {
                Label("Transcript still processing — speech appears when it's done.", systemImage: "hourglass")
                    .font(.system(size: 12))
                    .foregroundColor(.subtleText)
            } else {
                sendBar
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .narration(let text):
                    NarrationRow(text: text)
                case .annotation(let annotation, let speech):
                    AnnotationCard(annotation: annotation, speech: speech, image: thumbnails[annotation.id])
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// Hands the review to an assistant to implement.
    private var sendBar: some View {
        HStack(spacing: 8) {
            ForEach(AIHandoff.Target.allCases, id: \.self) { target in
                Button {
                    appState.sendToAI(meeting, target: target)
                } label: {
                    Label("Send to \(target.name)", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(target == .claude ? .accent : nil)
            }
            Text("Copies the review, screenshots and transcript; paste with ⌘V.")
                .font(.system(size: 11))
                .foregroundColor(.subtleText)
        }
        .disabled(appState.exportingMeetingIDs.contains(meeting.id))
    }

    private func load() async {
        let storage = appState.storageManager
        let id = meeting.id
        let (result, images) = await Task.detached { () -> ([LearningReview.Block], [UUID: CGImage]) in
            let annotations = (try? storage.fetchAnnotations(meetingId: id)) ?? []
            let segments = (try? storage.fetchTranscriptSegments(meetingId: id)) ?? []
            var images: [UUID: CGImage] = [:]
            for annotation in annotations {
                let url = RecordingManager.recordingsDirectory.appendingPathComponent(annotation.cropPath ?? annotation.screenshotPath)
                images[annotation.id] = Self.thumbnail(url)
            }
            return (annotations.isEmpty ? [] : LearningReview.blocks(annotations: annotations, segments: segments), images)
        }.value
        blocks = result
        thumbnails = images.mapValues { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        loaded = true
    }

    /// At most 1200 px on the long side — plenty for a card, a fraction of a
    /// full Retina screenshot.
    private nonisolated static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct NarrationRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.divider)
                .frame(width: 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.subtleText)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AnnotationCard: View {
    let annotation: Annotation
    let speech: String
    let image: NSImage?

    private func url(_ relative: String) -> URL {
        RecordingManager.recordingsDirectory.appendingPathComponent(relative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: annotation.isMarker ? "bookmark.fill" : "pencil.tip")
                    .foregroundColor(.accent)
                Text(annotation.isMarker ? "Marker \(annotation.index)" : "Annotation \(annotation.index)")
                    .font(.system(size: 13, weight: .semibold))
                Text(timeRange)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.subtleText)
                Spacer()
                Button {
                    NSWorkspace.shared.open(url(annotation.screenshotPath))
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.subtleText)
                .help("Open the full screenshot")
            }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.divider))
                    .onTapGesture { NSWorkspace.shared.open(url(annotation.screenshotPath)) }
            }

            let labels = annotation.marks.compactMap { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accent.opacity(0.18)))
                    }
                }
            }

            Text(speech.isEmpty ? String(localized: "No speech during this annotation.") : speech)
                .font(.system(size: 13))
                .foregroundColor(speech.isEmpty ? .subtleText : .primary)
                .italic(speech.isEmpty)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBg))
    }

    private var timeRange: String {
        let start = LearningReview.timestamp(annotation.startTime)
        return annotation.isMarker ? start : "\(start)–\(LearningReview.timestamp(annotation.endTime))"
    }
}
