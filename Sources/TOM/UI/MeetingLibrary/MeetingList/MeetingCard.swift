import SwiftUI

// MARK: - Meeting Card

struct MeetingCard: View {
    let meeting: Meeting
    let isSelected: Bool
    let isHovered: Bool

    @ObservedObject private var queue = ProcessingQueue.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accent.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: meeting.kind.icon)
                        .font(.system(size: 11))
                        .foregroundColor(.accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if queue.isQueued(meeting.id) {
                        // Hourglass in front of the title flags the meeting as
                        // waiting in the inference queue. Disappears the moment
                        // the worker picks it up — at which point the State
                        // Badge to the right takes over with "Transcribing".
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                            .help("Queued — waiting for the AI pipeline to free up")
                    }
                    if appState.renamingMeetingID == meeting.id {
                        MeetingTitleField(title: meeting.title, fontSize: 13) { newTitle in
                            if let newTitle { appState.renameMeeting(id: meeting.id, title: newTitle) }
                            appState.renamingMeetingID = nil
                        }
                    } else {
                        Text(meeting.title)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(isSelected ? .accent : .primary)
                            .lineLimit(1)
                    }
                }

                HStack {
                    if meeting.state == .recording, appState.isRecording {
                        // Live elapsed time, ticking every second while the
                        // recording runs — duration is only persisted at stop.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(formatDuration(appState.recordingElapsed(at: context.date)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red)
                        }
                    } else {
                        Text(formatDuration(meeting.duration))
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .accent.opacity(0.7) : .subtleText)
                    }
                    Spacer()
                    Text(shortDateFormatter.string(from: meeting.date))
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .accent.opacity(0.7) : .subtleText)
                }
            }

            Spacer()

            if meeting.state != .completed {
                StateBadge(state: meeting.state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accent.opacity(0.12) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Meeting Title Field

/// Inline title editor. Return or clicking away saves, Esc cancels;
/// `onFinish` receives the new text, or nil on cancel. Blank text releases
/// the title back to the AI (see `Meeting.rename(to:)`).
struct MeetingTitleField: View {
    let title: String
    let fontSize: CGFloat
    let onFinish: (String?) -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Recording title", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accent.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accent.opacity(0.5), lineWidth: 1)
            )
            .focused($focused)
            .onAppear {
                text = title
                focused = true
            }
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(text) }
            }
    }

    /// Submit and the focus loss it triggers both land here; only the first counts.
    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        onFinish(value)
    }
}

// MARK: - State Badge

struct StateBadge: View {
    let state: MeetingState
    private var color: Color {
        switch state {
        case .recording: .red; case .transcribing: .yellow; case .processing: .orange
        case .completed: .accent; case .failed: .red
        }
    }
    private var label: String {
        switch state {
        case .recording: "Recording"; case .transcribing: "Transcribing"; case .processing: "Processing"
        case .completed: "Completed"; case .failed: "Failed"
        }
    }
    var body: some View {
        Text(label).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.3)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.15)).foregroundColor(color).clipShape(Capsule())
    }
}
