import ScreenCaptureKit
import SwiftUI

// MARK: - Record Panel

/// Everything needed to start a recording in one place: mode, what to
/// record, audio options. Opens from the toolbar chevron (popover) and the
/// menu bar (small window). Choices are remembered and preselected the next
/// time it opens.
struct RecordPanel: View {
    @EnvironmentObject var appState: AppState
    /// Closes the popover or window hosting the panel.
    let onDone: () -> Void

    @State private var windowSelection: CGWindowID?
    @State private var displaySelection: CGDirectDisplayID?
    @State private var liveTranscript = LiveTranscription.isEnabled
    @State private var devices: [MicInput.Device] = []
    @State private var selectedDeviceUID = MicInput.selectedUID
    @StateObject private var meter = MicLevelMonitor()

    private var setup: Binding<RecordingSetup> { $appState.recordingSetup }
    private var mode: RecordingSetup.Mode { appState.recordingSetup.mode }
    private var source: RecordingSetup.Source { appState.recordingSetup.source }

    /// Other apps' windows; TOM's own can't usefully record themselves.
    private var windows: [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return appState.availableWindows.filter { $0.owningApplication?.processID != pid }
    }

    private var canStart: Bool {
        guard appState.canCreateMeetings, !appState.isRecording, appState.recordingSetup.hasAudio else { return false }
        switch mode {
        case .voiceNote: return true
        case .meeting, .feedback: return source == .screen ? selectedDisplay != nil : selectedWindow != nil
        }
    }

    private var selectedWindow: SCWindow? { windows.first { $0.windowID == windowSelection } }
    private var selectedDisplay: SCDisplay? { appState.availableDisplays.first { $0.displayID == displaySelection } }

    var body: some View {
        VStack(spacing: 0) {
            modeRow
            if mode != .voiceNote {
                sourceHeader
                sourceGrid
            }
            Divider()
            options
            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear {
            appState.refreshWindows()
            windowSelection = appState.lastWindow?.windowID
            displaySelection = appState.lastDisplay?.displayID
            devices = MicInput.devices()
            updateMeter()
        }
        .onDisappear { meter.stop() }
        .onChange(of: appState.recordingSetup.microphone) { updateMeter() }
        .onChange(of: mode) { updateMeter() }
        .onChange(of: appState.availableDisplays.map(\.displayID)) {
            if displaySelection == nil { displaySelection = appState.lastDisplay?.displayID }
        }
    }

    // MARK: Mode

    private var modeRow: some View {
        HStack(spacing: 3) {
            modeSegment(.meeting, title: "Meeting", icon: "video")
            modeSegment(.voiceNote, title: "Voice note", icon: "mic")
            modeSegment(.feedback, title: "Feedback", icon: "pencil.and.scribble")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func modeSegment(_ value: RecordingSetup.Mode, title: LocalizedStringKey, icon: String) -> some View {
        let selected = mode == value
        return Button {
            setup.wrappedValue.mode = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(selected ? .accent : .subtleText)
                Text(title)
                    .fontWeight(selected ? .semibold : .medium)
                    .foregroundColor(selected ? .primary : .subtleText)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.cardBg : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.divider : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Source

    private var sourceHeader: some View {
        HStack {
            Text("Record")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.subtleText)
            Spacer()
            HStack(spacing: 4) {
                sourceTab(.window, title: "Window")
                sourceTab(.screen, title: "Screen")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func sourceTab(_ value: RecordingSetup.Source, title: LocalizedStringKey) -> some View {
        let selected = source == value
        return Button {
            setup.wrappedValue.source = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selected ? .accent : .subtleText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accent.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
    }

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var sourceGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 10) {
                if source == .screen {
                    ForEach(appState.availableDisplays, id: \.displayID) { display in
                        SourceCell(
                            thumbnail: appState.displayThumbnails[display.displayID],
                            title: appState.displayName(for: display),
                            subtitle: "\(display.width) × \(display.height)",
                            placeholderIcon: "display",
                            isSelected: displaySelection == display.displayID
                        ) { displaySelection = display.displayID }
                    }
                } else {
                    ForEach(windows, id: \.windowID) { window in
                        SourceCell(
                            thumbnail: appState.windowThumbnails[window.windowID],
                            title: window.owningApplication?.applicationName ?? String(localized: "Window"),
                            subtitle: window.title ?? "",
                            placeholderIcon: "macwindow",
                            isSelected: windowSelection == window.windowID
                        ) { windowSelection = window.windowID }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(height: 262)
        .overlay {
            if (source == .screen ? appState.availableDisplays.isEmpty : windows.isEmpty) {
                Text(source == .screen ? "No displays available" : "No windows available")
                    .font(.system(size: 12))
                    .foregroundColor(.subtleText)
            }
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(spacing: 0) {
            OptionRow(icon: "mic", title: "Microphone", divider: true) {
                Menu {
                    Button("System default") { selectDevice(nil) }
                    Divider()
                    ForEach(devices) { device in
                        Button(device.name) { selectDevice(device.uid) }
                    }
                } label: {
                    Text("\(currentDeviceName) \(Image(systemName: "chevron.down"))")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } trailing: {
                LevelMeter(level: appState.recordingSetup.microphone || mode == .voiceNote ? meter.level : 0)
                if mode != .voiceNote {
                    Toggle("", isOn: setup.microphone).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(.accent)
                }
            }

            if mode != .voiceNote {
                OptionRow(icon: "speaker.wave.2", title: "System audio", divider: true) {
                    Text(source == .window ? "Sound from the recorded window's app" : "All sound playing on this Mac")
                } trailing: {
                    Toggle("", isOn: setup.systemAudio).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(.accent)
                }
            }

            if mode == .feedback {
                OptionRow(icon: "keyboard", title: "Annotation hotkeys", divider: false) {
                    Text("⌥A annotate · ⌥M mark · Esc cancel")
                } trailing: { EmptyView() }
            } else {
                OptionRow(icon: "captions.bubble", title: "Live transcript", divider: false) {
                    Text("Words appear while you talk")
                } trailing: {
                    Toggle("", isOn: $liveTranscript).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(.accent)
                        .onChange(of: liveTranscript) { LiveTranscription.set(liveTranscript) }
                }
            }

            if !appState.recordingSetup.hasAudio {
                Label("Turn on the microphone or system audio to get a transcript.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var currentDeviceName: String {
        if let uid = selectedDeviceUID, let device = devices.first(where: { $0.uid == uid }) { return device.name }
        return MicInput.currentDeviceName()
    }

    private func selectDevice(_ uid: String?) {
        MicInput.selectedUID = uid
        selectedDeviceUID = uid
        tomLog("User action: microphone → \(uid == nil ? "system default" : currentDeviceName)")
        updateMeter()
    }

    private func updateMeter() {
        if (appState.recordingSetup.microphone || mode == .voiceNote) && !appState.isRecording {
            meter.start()
        } else {
            meter.stop()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                onDone()
                AppDelegate.shared?.showImportPicker(appState: appState)
            } label: {
                Label("Upload recording…", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12))
                    .foregroundColor(.subtleText)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("↩")
                .font(.system(size: 11))
                .foregroundColor(.subtleText)
            Button(action: start) {
                Label("Start recording", systemImage: "record.circle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(LinearGradient(colors: [.accent, Color(red: 0.85, green: 0.46, blue: 0.11)], startPoint: .top, endPoint: .bottom)))
                    .opacity(canStart ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
    }

    private func start() {
        meter.stop()
        switch mode {
        case .voiceNote:
            appState.startVoiceNote()
        case .feedback:
            if source == .screen, let display = selectedDisplay {
                appState.startFeedback(display: display)
            } else if let window = selectedWindow {
                appState.startFeedback(window: window)
            }
        case .meeting:
            if source == .screen, let display = selectedDisplay {
                tomLog("User action: Record panel → display \(display.displayID)")
                appState.startRecording(display: display)
            } else if let window = selectedWindow {
                tomLog("User action: Record panel → window \(window.windowID) (\(window.owningApplication?.bundleIdentifier ?? "?"))")
                appState.startRecording(window: window)
            }
        }
        onDone()
    }
}

// MARK: - Pieces

private struct SourceCell: View {
    let thumbnail: NSImage?
    let title: String
    let subtitle: String
    let placeholderIcon: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                // Fixed-size box the thumbnail fills; the overlay keeps a
                // wide image from widening the grid column.
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 78)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: placeholderIcon)
                                .font(.system(size: 22))
                                .foregroundColor(.subtleText)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.subtleText)
                }
                .lineLimit(1)
                .padding(.horizontal, 3)
                .padding(.bottom, 3)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accent.opacity(0.1) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accent : Color.divider, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(subtitle.isEmpty ? title : "\(title) — \(subtitle)")
    }
}

private struct OptionRow<Detail: View, Trailing: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let divider: Bool
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                detail
                    .font(.system(size: 10.5))
                    .foregroundColor(.subtleText)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color.divider).frame(height: 1) }
        }
    }
}

/// Five-bar input meter.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let heights: [CGFloat] = [5, 8, 11, 13, 14]
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > Float(i) * 0.12 + 0.02 ? Color.green : Color.primary.opacity(0.15))
                    .frame(width: 3, height: heights[i])
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
