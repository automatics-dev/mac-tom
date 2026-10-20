import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Logging

/// Single entry point for runtime logs. Calls NSLog (so Xcode console +
/// Console.app keep working in dev) and appends a timestamped line to
/// `~/Library/Logs/TOM/tom.log` so production builds launched from
/// Finder can be inspected after the fact — open the file via
/// Settings → About → "Open log file".
///
/// Free function on purpose: callable from any actor / isolation context
/// without ceremony. All 100+ TOM log sites route through here.
func tomLog(_ message: String) {
    NSLog("[TOM] %@", message)
    TOMLogFile.shared.append(message)
}

/// Backing file logger. Truncates on first open so each launch starts
/// with a clean log — the user gets exactly one session's worth of
/// runtime trace, never a mix from prior runs. Writes are serialised on
/// a private dispatch queue so concurrent callers never interleave bytes.
final class TOMLogFile: @unchecked Sendable {
    static let shared = TOMLogFile()

    private let queue = DispatchQueue(label: "tom.log.file")
    private var handle: FileHandle?

    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/TOM/tom.log", isDirectory: false)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func append(_ message: String) {
        let ts = Self.formatter.string(from: Date())
        let line = "\(ts) [TOM] \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil { self.openHandle() }
            guard let handle = self.handle,
                  let data = line.data(using: .utf8)
            else { return }
            try? handle.write(contentsOf: data)
        }
    }

    /// Opens the log file *truncating* any prior content — the file is
    /// owned by exactly one TOM process at a time and each launch wants a
    /// fresh trace. Creates the parent directory on first run.
    private func openHandle() {
        let url = Self.logURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Recreate the file empty (drops any previous-session content).
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let banner = "==== TOM session started \(Self.formatter.string(from: Date())) version \(version) ====\n"
        try? handle?.write(contentsOf: Data(banner.utf8))
    }
}

@main
struct TOMApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updater = UpdaterController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window scene — singleton by design (macOS 13.0+).
        // openWindow(id: "meeting-library") existing pencere varsa onu öne getirir,
        // yoksa yeni pencere açar. WindowGroup KULLANMA — her çağrıda yeni pencere açar.
        Window(AppDelegate.libraryTitle, id: "meeting-library") {
            MeetingLibraryView()
                .environmentObject(appState)   // view-level enjeksiyon — Scene.environmentObject macOS 14+ gerektirir
                .environmentObject(updater)
        }
        .defaultSize(width: 900, height: 600)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        // Menu bar icon: a manually managed NSStatusItem
        // (StatusItemController), NOT a MenuBarExtra scene.
        // MenuBarExtra(isInserted:) silently failed to register the item on
        // macOS 26 after a Sparkle relaunch (1.22.0 shipped unreachable:
        // no icon, no window, accessory policy). The NSStatusItem is
        // installed in applicationDidFinishLaunching and toggled from
        // Settings; the Dock icon is always present as the safety net.
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?

    /// Library window title; also how the window is found again, so it's
    /// the same localized string in both places.
    static let libraryTitle = String(localized: "TOM — Library")

    private var meetingDetailWindow: NSWindow?
    private var recordPanelWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    private func applyAppIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyAppIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        applyAppIcon()

        // Request notification permission (requires app bundle)
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                tomLog("Notification auth request: granted=\(granted) error=\(String(describing: error))")
            }
            center.getNotificationSettings { settings in
                tomLog("Notification settings: authStatus=\(settings.authorizationStatus.rawValue) alertSetting=\(settings.alertSetting.rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
            }

            let recordAction = UNNotificationAction(
                identifier: "RECORD",
                title: String(localized: "Start Recording"),
                options: [.foreground]
            )
            let category = UNNotificationCategory(
                identifier: "MEETING_DETECTED",
                actions: [recordAction],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            center.setNotificationCategories([category])
        }

        // Auto-register login item on first launch
        if !UserDefaults.standard.bool(forKey: "tom.loginItemConfigured") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "tom.loginItemConfigured")
            UserDefaults.standard.set(true, forKey: "tom.launchAtLogin")
        }

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "tom.onboardingCompleted") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showOnboarding()
            }
        }

        // TOM is a regular app: Dock icon always visible (LSUIElement was
        // removed). No accessory-policy juggling — the old hide-in-menu-bar
        // lifecycle left the app unreachable when the menu bar icon failed
        // to register (1.22.0 incident).
        NSApp.setActivationPolicy(.regular)

        // Menu bar icon (optional, default on) — deterministic NSStatusItem.
        StatusItemController.shared.installIfEnabled()

        // TOOLBAR-05: Appearance preference restore — view hiyerarşisi kurulmadan önce uygula.
        // .onAppear içinde yapılırsa başlangıçta light→dark flicker oluşur.
        // Default follows the system appearance (NSApp.appearance = nil).
        AppearancePreference.current.apply()
    }

    /// Dock icon click with no visible window → reopen the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let appState = AppState.shared {
            showDashboard(appState: appState)
        }
        return true
    }

    /// Keep running when the last window closes — TOM lives in the Dock and
    /// menu bar and must survive the dashboard being closed (recordings and
    /// the processing pipeline continue in the background). Without this,
    /// the now-single-scene SwiftUI app terminates on window close.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Notification Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let isMeetingDetected = (userInfo["type"] as? String) == "meetingDetected"
        let sessionID = userInfo["sessionID"] as? String
        let windowIDValue = (userInfo["windowID"] as? NSNumber)?.uint32Value

        await MainActor.run {
            if isMeetingDetected {
                if actionIdentifier == UNNotificationDismissActionIdentifier {
                    tomLog("User action: dismissed meeting-detected notification (sessionID=\(sessionID ?? "?"))")
                    if let sessionID {
                        AppState.shared?.markMeetingDismissed(sessionID: sessionID)
                    }
                    return
                }
                if actionIdentifier == "RECORD" {
                    tomLog("User action: tapped Start Recording on meeting notification (windowID=\(windowIDValue?.description ?? "?"))")
                    if let windowIDValue {
                        AppState.shared?.startRecordingByWindowID(CGWindowID(windowIDValue))
                    }
                    return
                }
                // Default tap on the notification body — open the dashboard
                // rather than activating with no visible window.
                tomLog("User action: tapped meeting-detected notification body → open Dashboard")
                if let appState = AppState.shared {
                    self.showDashboard(appState: appState)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
                return
            }

            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func activateApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func showDashboard(appState: AppState) {
        activateApp()
        if let window = NSApp.windows.first(where: { $0.title == AppDelegate.libraryTitle }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    func showMeetingDetail(meeting: Meeting, appState: AppState) {
        activateApp()
        if let window = meetingDetailWindow {
            window.contentView = NSHostingView(
                rootView: MeetingDetailView(meeting: meeting, playerManager: appState.playerManager)
                    .environmentObject(appState)
            )
            window.title = "TOM — \(meeting.title)"
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            title: "TOM — \(meeting.title)",
            size: NSSize(width: 1000, height: 600),
            view: MeetingDetailView(meeting: meeting, playerManager: appState.playerManager)
                .environmentObject(appState)
        )
        meetingDetailWindow = window
    }

    /// The record panel in a small window, for entry points without a
    /// toolbar to anchor a popover (menu bar, missing last window).
    @MainActor
    func showRecordPanel(appState: AppState) {
        activateApp()
        if let window = recordPanelWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        recordPanelWindow?.close()
        var window: NSWindow?
        let panel = RecordPanel { window?.close() }.environmentObject(appState)
        window = makeWindow(title: String(localized: "Record"), size: NSSize(width: 520, height: 560), view: panel)
        window?.styleMask.remove(.resizable)
        window?.setContentSize(window?.contentView?.fittingSize ?? NSSize(width: 520, height: 560))
        recordPanelWindow = window
    }

    @MainActor
    func showImportPicker(appState: AppState) {
        activateApp()
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Recordings")
        panel.message = String(localized: "Select one or more audio or video files. Each file is processed sequentially through transcription, summary, and embeddings — files beyond the first show a Queued badge in the recording list.")
        panel.prompt = String(localized: "Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mpeg4Audio, .mp3, .wav]
        panel.begin { response in
            guard response == .OK else {
                tomLog("User action: Import picker cancelled")
                return
            }
            let urls = panel.urls
            guard !urls.isEmpty else {
                tomLog("User action: Import picker confirmed with no selection")
                return
            }
            tomLog("User action: Import picker confirmed (\(urls.count) file\(urls.count == 1 ? "" : "s"))")
            Task { @MainActor in
                for url in urls {
                    appState.importRecording(from: url)
                }
                AppDelegate.shared?.showDashboard(appState: appState)
            }
        }
    }

    @MainActor
    func showOnboarding() {
        activateApp()
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            title: String(localized: "Welcome to TOM"),
            size: NSSize(width: 500, height: 420),
            view: OnboardingView()
        )
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.miniaturizable)
        onboardingWindow = window
    }

    @MainActor
    func showSettings(appState: AppState) {
        activateApp()
        if let window = NSApp.windows.first(where: { $0.title == AppDelegate.libraryTitle }) {
            window.makeKeyAndOrderFront(nil)
        }
        withAnimation(.spring(duration: 0.3)) {
            appState.showSettings = true
        }
    }

    private func makeWindow<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        return window
    }

}
