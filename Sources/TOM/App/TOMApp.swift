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
        Window("TOM — Meeting Library", id: "meeting-library") {
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

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(updater)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(appState.isRecording ? .multicolor : .monochrome)
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?

    private var meetingDetailWindow: NSWindow?
    private var windowPickerWindow: NSWindow?
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
                title: "Start Recording",
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

        // Window scene NSWindow lazy oluşturulur (applicationDidFinishLaunching anında mevcut değil).
        // Delegate ataması yerine NotificationCenter ile close olayını dinle (Tuzak 5; RESEARCH Desen 3).
        // Secondary window'lar (settings/picker/onboarding/meetingDetail) zaten makeWindow() içinde
        // window.delegate = self ile NSWindowDelegate yolundan tetiklenir; bu observer Window scene
        // NSWindow'unu da aynı handleWindowClose mantığına dahil eder.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowClose()
        }

        // LSUIElement fix: .accessory policy'deyken bir pencere key olursa .regular'a geç.
        // Window scene SwiftUI tarafından açılır ama policy değişmez — bu yüzden TextField
        // key window olamaz ve klavye input gelmiyor. Her key window olayında kontrol et.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard NSApp.activationPolicy() != .regular else { return }
            self?.activateApp()
        }

        // TOOLBAR-05: Appearance preference restore — view hiyerarşisi kurulmadan önce uygula.
        // .onAppear içinde yapılırsa başlangıçta light→dark flicker oluşur.
        let prefersDark = UserDefaults.standard.bool(forKey: "tom.prefersDark")
        NSApp.appearance = prefersDark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
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
        if let window = NSApp.windows.first(where: { $0.title == "TOM — Meeting Library" }) {
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

    @MainActor
    func showWindowPicker(appState: AppState) {
        activateApp()
        if let window = windowPickerWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        appState.refreshWindows()
        let window = makeWindow(
            title: "Choose What to Record",
            size: NSSize(width: 700, height: 500),
            view: WindowPickerView().environmentObject(appState)
        )
        window.styleMask.remove(.resizable)
        windowPickerWindow = window
    }

    @MainActor
    func showImportPicker(appState: AppState) {
        activateApp()
        let panel = NSOpenPanel()
        panel.title = "Import Recordings"
        panel.message = "Select one or more audio or video files. Each file is processed sequentially through transcription, summary, and embeddings — files beyond the first show a Queued badge in the meeting list."
        panel.prompt = "Import"
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
            title: "Welcome to TOM",
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
        if let window = NSApp.windows.first(where: { $0.title == "TOM — Meeting Library" }) {
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

    func windowWillClose(_ notification: Notification) {
        // Secondary window'lar (Settings/Picker/Onboarding/MeetingDetail) hâlâ AppDelegate'in
        // NSWindowDelegate'i — bu yol ile tetiklenir. Window scene NSWindow'u için ayrı
        // NotificationCenter observer (applicationDidFinishLaunching içinde) handleWindowClose'u çağırır.
        handleWindowClose()
    }

    private func handleWindowClose() {
        DispatchQueue.main.async {
            // Window scene NSWindow'u title ile bulunur — dashboardWindow referansı kaldırıldı.
            // String literal Task 1'deki Window scene title ile birebir aynı olmalı.
            let dashboardIsVisible = NSApp.windows.first(where: {
                $0.title == "TOM — Meeting Library" && $0.isVisible
            }) != nil
            let hasVisible = dashboardIsVisible
                || self.meetingDetailWindow?.isVisible == true
                || self.windowPickerWindow?.isVisible == true
                || self.onboardingWindow?.isVisible == true   // YENİ: mevcut eksiklik kapatıldı (D-02 + Tuzak 4)
            if !hasVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Menu Bar Content

private struct MenuBarContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updater: UpdaterController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if appState.isRecording {
            Text("Recording...")
                .foregroundColor(.red)

            if !appState.currentTranscript.isEmpty {
                Text(String(appState.currentTranscript.suffix(80)))
                    .font(.caption)
                    .lineLimit(2)
            }

            Divider()

            Button("Stop Recording") {
                tomLog("User action: Stop Recording (menu bar)")
                Task { @MainActor in
                    appState.stopRecording()
                }
            }
        } else {
            if let reason = appState.recordingBlockedReason {
                Text(reason)
                    .font(.caption)
            }

            Button("Record a Window...") {
                tomLog("User action: Record a Window… (menu bar)")
                AppDelegate.shared?.showWindowPicker(appState: appState)
            }
            .disabled(!appState.canCreateMeetings)

            Button("Record Voice Note") {
                tomLog("User action: Record Voice Note (menu bar)")
                Task { @MainActor in
                    appState.startVoiceNote()
                }
            }
            .disabled(!appState.canCreateMeetings)

            Button("Upload Recording...") {
                tomLog("User action: Upload Recording… (menu bar)")
                AppDelegate.shared?.showImportPicker(appState: appState)
            }
            .disabled(!appState.canCreateMeetings)
        }

        Divider()

        Button("Open Dashboard") {
            tomLog("User action: Open Dashboard (menu bar)")
            // LSUIElement uygulaması: openWindow'dan önce activation policy .regular olmalı,
            // yoksa Window scene NSWindow key window olamaz (Tuzak 3).
            // Sıralama önemli: setActivationPolicy → activate → openWindow.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "meeting-library")
        }

        Button("Settings") {
            tomLog("User action: Open Settings (menu bar)")
            AppDelegate.shared?.showSettings(appState: appState)
        }

        Button("Check for Updates…") {
            tomLog("User action: Check for Updates… (menu bar)")
            updater.checkForUpdates()
        }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit") {
            tomLog("User action: Quit (menu bar)")
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

}
