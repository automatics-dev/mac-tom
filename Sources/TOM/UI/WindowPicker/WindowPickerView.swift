import SwiftUI
import ScreenCaptureKit

struct WindowPickerView: View {
    @EnvironmentObject var appState: AppState

    enum PickerTab { case entireScreen, applicationWindow }
    enum Selection: Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    @State private var activeTab: PickerTab = .applicationWindow
    @State private var selection: Selection?

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Choose what to record")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // Tabs
            HStack(spacing: 0) {
                PickerTabButton(
                    title: "Entire Screen",
                    icon: "display",
                    isSelected: activeTab == .entireScreen
                ) {
                    activeTab = .entireScreen
                    selection = nil
                }
                PickerTabButton(
                    title: "Application Window",
                    icon: "macwindow",
                    isSelected: activeTab == .applicationWindow
                ) {
                    activeTab = .applicationWindow
                    selection = nil
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            // Content
            switch activeTab {
            case .entireScreen:
                screenGrid
            case .applicationWindow:
                windowGrid
            }

            // Footer
            Divider()
            HStack {
                Button("Refresh") {
                    appState.refreshWindows()
                }
                Spacer()
                Button("Cancel") {
                    tomLog("User action: Window picker cancelled")
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button("Record") {
                    startSelected()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 700, height: 500)
    }

    // MARK: - Screen Grid

    private var screenGrid: some View {
        Group {
            if appState.availableDisplays.isEmpty {
                emptyState(icon: "display", text: "No displays available")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(appState.availableDisplays, id: \.displayID) { display in
                            PickerCell(
                                thumbnail: appState.displayThumbnails[display.displayID],
                                appIcon: nil,
                                title: displayName(display),
                                isSelected: selection == .display(display.displayID)
                            ) {
                                selection = .display(display.displayID)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    // MARK: - Window Grid

    private var windowGrid: some View {
        Group {
            if appState.availableWindows.isEmpty {
                emptyState(icon: "macwindow.on.rectangle", text: "No windows available")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(appState.availableWindows, id: \.windowID) { window in
                            PickerCell(
                                thumbnail: appState.windowThumbnails[window.windowID],
                                appIcon: appIcon(for: window),
                                title: window.title ?? window.owningApplication?.applicationName ?? "Window",
                                isSelected: selection == .window(window.windowID)
                            ) {
                                selection = .window(window.windowID)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    // MARK: - Helpers

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(text)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func displayName(_ display: SCDisplay) -> String {
        if CGDisplayIsBuiltin(display.displayID) != 0 {
            return "Built-in Display"
        }
        let externals = appState.availableDisplays.filter { CGDisplayIsBuiltin($0.displayID) == 0 }
        if externals.count > 1, let idx = externals.firstIndex(where: { $0.displayID == display.displayID }) {
            return "External Display \(idx + 1)"
        }
        return "External Display"
    }

    private func appIcon(for window: SCWindow) -> NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func startSelected() {
        guard let selection else { return }
        switch selection {
        case .display(let displayID):
            if let display = appState.availableDisplays.first(where: { $0.displayID == displayID }) {
                tomLog("User action: Window picker → Record display id=\(displayID) (\(display.width)x\(display.height))")
                appState.startRecording(display: display)
            }
        case .window(let windowID):
            if let window = appState.availableWindows.first(where: { $0.windowID == windowID }) {
                let bundle = window.owningApplication?.bundleIdentifier ?? "?"
                let title = window.title ?? window.owningApplication?.applicationName ?? "?"
                tomLog("User action: Window picker → Record window id=\(windowID) bundle=\(bundle) title=\(title.debugDescription)")
                appState.startRecording(window: window)
            }
        }
        closeWindow()
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

// MARK: - Picker Cell

private struct PickerCell: View {
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .padding(6)
                    }
                }
                .frame(height: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? Color.accentColor : (isHovering ? Color.primary.opacity(0.2) : Color.clear),
                            lineWidth: isSelected ? 3 : 2
                        )
                )

                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Picker Tab Button

private struct PickerTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
