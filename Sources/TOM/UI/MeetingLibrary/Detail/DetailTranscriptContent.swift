import SwiftUI

// MARK: - Detail Transcript Content

struct DetailTranscriptContent: View {
    let meeting: Meeting
    @ObservedObject var playerManager: PlayerManager
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !playerManager.segments.isEmpty {
            segmentList
        } else if let live = appState.liveTranscripts[meeting.id] {
            liveTranscription(live, volatile: appState.liveVolatile[meeting.id] ?? "")
        } else if let transcript = meeting.transcript, !transcript.isEmpty {
            ScrollView {
                Text(transcript)
                    .font(.system(size: 13))
                    .foregroundColor(.dimText)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        } else if meeting.state == .completed {
            Spacer()
            Text("No transcript available.")
                .font(.system(size: 13))
                .foregroundColor(.subtleText)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).progressViewStyle(.circular)
                Text("Processing...").font(.system(size: 13)).foregroundColor(.subtleText).italic()
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    /// Streaming preview with follow-along scrolling — the newest utterance
    /// stays visible as text flows in.
    private func liveTranscription(_ live: String, volatile: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LiveTranscriptionView(text: live, volatile: volatile)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("liveBottom")
            }
            .scrollIndicators(.hidden)
            .onChange(of: live + volatile) { _ in
                proxy.scrollTo("liveBottom", anchor: .bottom)
            }
        }
    }

    private var segmentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(playerManager.segments) { segment in
                    SegmentRow(
                        segment: segment,
                        playerManager: playerManager,
                        displayName: meeting.speakerAliases[segment.speaker] ?? segment.speaker
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Segment Row
// Observes playerManager directly so only the two affected rows redraw on each 100 ms tick.

private struct SegmentRow: View {
    let segment: TranscriptSegment
    @ObservedObject var playerManager: PlayerManager
    let displayName: String

    private var isCurrent: Bool {
        guard let idx = playerManager.segments.firstIndex(where: { $0.id == segment.id }) else { return false }
        return idx == playerManager.currentSegmentIndex
    }

    var body: some View {
        TranscriptSegmentRow(
            segment: segment,
            isCurrent: isCurrent,
            displayName: displayName,
            onRename: { _ in }
        )
    }
}
