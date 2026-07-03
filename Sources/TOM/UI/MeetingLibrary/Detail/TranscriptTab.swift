import SwiftUI

// MARK: - Transcript Tab

struct TranscriptTabContent: View {
    let meeting: Meeting
    @ObservedObject var playerManager: PlayerManager
    @EnvironmentObject var appState: AppState

    /// Latest meeting state from AppState — speaker renames go through AppState
    /// and we want the new alias to render without the parent re-creating us.
    private var liveMeeting: Meeting {
        appState.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !playerManager.segments.isEmpty {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(playerManager.segments.enumerated()), id: \.element.id) { idx, segment in
                        TranscriptSegmentRow(
                            segment: segment,
                            isCurrent: idx == playerManager.currentSegmentIndex,
                            displayName: liveMeeting.speakerAliases[segment.speaker] ?? segment.speaker,
                            onRename: { newName in
                                appState.renameSpeaker(
                                    meetingId: liveMeeting.id,
                                    raw: segment.speaker,
                                    alias: newName
                                )
                            }
                        )
                        .id(segment.id)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            } else if let transcript = liveMeeting.aliasedTranscript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 14))
                    .foregroundColor(.dimText)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
            } else if meeting.state == .completed {
                Text("No transcript available")
                    .font(.system(size: 14))
                    .foregroundColor(.subtleText)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(.circular)
                    Text("Processing...")
                        .font(.system(size: 14))
                        .foregroundColor(.subtleText)
                        .italic()
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }

            Spacer(minLength: 20)
        }
    }
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let displayName: String
    let onRename: (String) -> Void

    @State private var showRenameDialog = false
    @State private var renameInput = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.accent.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .onTapGesture {
                            renameInput = displayName == segment.speaker ? "" : displayName
                            showRenameDialog = true
                        }
                        .help("Click to rename \(segment.speaker)")

                    Text(formatTimestamp(segment.startTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.subtleText)
                }

                Text(segment.text)
                    .font(.system(size: 14))
                    .foregroundColor(isCurrent ? .primary : .dimText)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accent.opacity(0.06) : Color.clear)
        )
        .alert("Rename \(segment.speaker)", isPresented: $showRenameDialog) {
            TextField("Display name", text: $renameInput)
            Button("Cancel", role: .cancel) {}
            Button("Save") { onRename(renameInput) }
        } message: {
            Text("Set a custom name for this speaker. Leave empty to reset to \(segment.speaker).")
        }
    }
}
