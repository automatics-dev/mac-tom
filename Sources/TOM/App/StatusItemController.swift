import AppKit
import Combine

/// Manually managed menu bar status item.
///
/// Replaces the SwiftUI `MenuBarExtra`, which proved unreliable:
/// `MenuBarExtra(isInserted:)` silently failed to register the item on
/// macOS 26 after a Sparkle relaunch (shipped in 1.22.0 — app became
/// unreachable). An `NSStatusItem` is created and removed imperatively, so
/// visibility is deterministic and the "Show menu bar icon" preference can
/// be honored safely. The Dock icon is always visible (regular activation
/// policy, set at launch), so hiding the status item never strands the user.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    static let shared = StatusItemController()

    static let visibilityKey = "tom.showMenuBarIcon"

    static var isVisible: Bool {
        (UserDefaults.standard.object(forKey: visibilityKey) as? Bool) ?? true
    }

    private var statusItem: NSStatusItem?
    private var isRecording = false

    private override init() { super.init() }

    // MARK: - Visibility

    func installIfEnabled() {
        if Self.isVisible { install() }
    }

    func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.visibilityKey)
        visible ? install() : remove()
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = icon()
        let menu = NSMenu()
        menu.autoenablesItems = false   // enabled state set explicitly per item
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Recording state

    /// Called from AppState whenever `isRecording` flips; swaps the icon.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        statusItem?.button?.image = icon()
    }

    private func icon() -> NSImage? {
        let name = isRecording ? "record.circle.fill" : "record.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "TOM")
        image?.isTemplate = !isRecording
        if isRecording {
            return image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            )
        }
        return image
    }

    // MARK: - Menu

    /// Rebuilds the menu each time it opens so it always reflects live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let appState = AppState.shared else {
            menu.addItem(disabledItem(String(localized: "Starting…")))
            return
        }

        if appState.isRecording {
            let elapsed = appState.recordingStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
            menu.addItem(disabledItem(String(format: String(localized: "Recording… %d:%02d"), elapsed / 60, elapsed % 60)))
            menu.addItem(MeetingMenuItem(String(localized: "Stop Recording"), systemImage: "stop.circle") {
                tomLog("User action: Stop Recording (menu bar)")
                Task { @MainActor in AppState.shared?.stopRecording() }
            })
        } else {
            if let reason = appState.recordingBlockedReason {
                menu.addItem(disabledItem(reason))
            }
            let canCreate = appState.canCreateMeetings
            menu.addItem(actionItem(String(localized: "Record a Window…"), systemImage: "rectangle.inset.filled.badge.record", enabled: canCreate) {
                tomLog("User action: Record a Window… (menu bar)")
                guard let state = AppState.shared else { return }
                AppDelegate.shared?.showWindowPicker(appState: state)
            })
            menu.addItem(actionItem(String(localized: "Record Voice Note"), systemImage: "mic", enabled: canCreate) {
                tomLog("User action: Record Voice Note (menu bar)")
                Task { @MainActor in AppState.shared?.startVoiceNote() }
            })
            menu.addItem(actionItem(String(localized: "Upload Recording…"), systemImage: "square.and.arrow.down", enabled: canCreate) {
                tomLog("User action: Upload Recording… (menu bar)")
                guard let state = AppState.shared else { return }
                AppDelegate.shared?.showImportPicker(appState: state)
            })
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Open Dashboard"), systemImage: "macwindow", enabled: true) {
            tomLog("User action: Open Dashboard (menu bar)")
            guard let state = AppState.shared else { return }
            AppDelegate.shared?.showDashboard(appState: state)
        })
        menu.addItem(actionItem(String(localized: "Settings"), systemImage: "gearshape", enabled: true) {
            tomLog("User action: Open Settings (menu bar)")
            guard let state = AppState.shared else { return }
            AppDelegate.shared?.showSettings(appState: state)
        })
        menu.addItem(actionItem(
            String(localized: "Check for Updates…"),
            systemImage: "arrow.triangle.2.circlepath",
            enabled: UpdaterController.shared?.canCheckForUpdates ?? false
        ) {
            tomLog("User action: Check for Updates… (menu bar)")
            Task { @MainActor in UpdaterController.shared?.checkForUpdates() }
        })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit TOM"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = MeetingMenuItem(title, systemImage: systemImage, action: action)
        item.isEnabled = enabled
        return item
    }
}
