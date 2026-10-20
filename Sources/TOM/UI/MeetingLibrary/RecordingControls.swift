import SwiftUI

// MARK: - Idle: Start Recording

/// Opens the record panel (also ⌘⇧R), where mode, source and audio are
/// picked before starting.
struct StartRecordingControl: View {
    @EnvironmentObject var appState: AppState
    @State private var showPanel = false

    var body: some View {
        Button {
            tomLog("User action: Start Recording (toolbar)")
            showPanel.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.accent.opacity(0.2)).frame(width: 16, height: 16)
                    Circle().fill(Color.accent).frame(width: 8, height: 8)
                }
                Text("Start Recording")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.accent.opacity(0.12))
                    .overlay(Capsule().stroke(Color.accent.opacity(0.35)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help(appState.recordingBlockedReason ?? String(localized: "Choose what and how to record (⌘⇧R)"))
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            RecordPanel { showPanel = false }
                .environmentObject(appState)
        }
        .fixedSize()
        .disabled(!appState.canCreateMeetings)
        .opacity(appState.canCreateMeetings ? 1 : 0.5)
    }
}

// MARK: - Recording bar

/// Timer, what's being recorded, and the controls that act on it: Annotate /
/// Mark in Feedback mode, mic mute, pause, Stop.
struct RecordingBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isPaused ? Color.orange : Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(appState.isPaused && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 0.3 : 1)
                    Text(formatDuration(appState.recordingElapsed(at: context.date)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            if !appState.recordingSourceLabel.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: sourceIcon)
                        .font(.system(size: 10))
                        .foregroundColor(appState.currentRecordingKind == .learning ? .accent : .subtleText)
                    Text(appState.recordingSourceLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.subtleText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 220)
                .help(appState.recordingSourceLabel)
            }

            if let learning = appState.learningSession {
                LearningBarButtons(session: learning)
            }

            if appState.currentRecordingKind != .voiceNote {
                CircleIconButton(
                    icon: appState.isMicMuted ? "mic.slash.fill" : "mic.fill",
                    tint: appState.isMicMuted ? .red : nil,
                    help: appState.isMicMuted ? String(localized: "Unmute microphone") : String(localized: "Mute microphone")
                ) { appState.toggleMicMute() }
            }

            CircleIconButton(
                icon: appState.isPaused ? "play.fill" : "pause.fill",
                tint: appState.isPaused ? .accent : nil,
                help: appState.isPaused ? String(localized: "Resume recording") : String(localized: "Pause recording")
            ) { appState.togglePause() }

            Button {
                tomLog("User action: Stop Recording (toolbar)")
                appState.stopRecording()
            } label: {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 8, height: 8)
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(red: 0.9, green: 0.28, blue: 0.3)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help(String(localized: "Stop the current recording (⌘⇧R)"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.cardBg)
                .overlay(Capsule().stroke(Color.divider))
        )
        .fixedSize()
    }

    private var sourceIcon: String {
        switch appState.currentRecordingKind {
        case .learning:  return "pencil.and.scribble"
        case .voiceNote: return "mic"
        default:         return appState.recordingSetup.source == .screen ? "display" : "macwindow"
        }
    }
}

/// Annotate (filled while a round is open) and Mark, mirroring ⌥A / ⌥M.
private struct LearningBarButtons: View {
    @ObservedObject var session: LearningSession

    var body: some View {
        CircleIconButton(
            icon: "pencil.tip",
            tint: session.isAnnotating ? .white : nil,
            fill: session.isAnnotating ? .accent : nil,
            help: session.isAnnotating ? String(localized: "Finish annotation (⌥A)") : String(localized: "Annotate (⌥A)")
        ) { session.toggleAnnotate() }
        CircleIconButton(icon: "flag", help: String(localized: "Mark this moment (⌥M)")) { session.addMarker() }
            .disabled(session.isAnnotating)
    }
}

private struct CircleIconButton: View {
    let icon: String
    var tint: Color?
    var fill: Color?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint ?? .primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(fill ?? Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
