import AppKit
import AVFoundation
import Foundation
import Combine
import ScreenCaptureKit
import UserNotifications

@MainActor
final class AppState: ObservableObject {

    /// Weak singleton accessor so non-SwiftUI surfaces (notification handlers
    /// in AppDelegate) can route actions back into app state without threading
    /// the instance through every call site.
    static private(set) weak var shared: AppState?

    // MARK: - Recording

    @Published var isRecording = false
    @Published var currentTranscript = ""
    @Published var availableWindows: [SCWindow] = []
    @Published var availableDisplays: [SCDisplay] = []
    @Published var recordingStartTime: Date?
    @Published var windowThumbnails: [CGWindowID: NSImage] = [:]
    @Published var displayThumbnails: [CGDirectDisplayID: NSImage] = [:]

    private var currentMeetingId: UUID?
    private(set) var currentRecordingKind: MeetingKind = .meeting

    /// Live-transcription session for the recording in progress (nil when
    /// live transcription is off or the model isn't ready). Created at
    /// recording start, drained via `finish()` after stop.
    private var liveSession: StreamingTranscriptionSession?

    /// Annotation overlay + hotkeys of the Learning recording in progress.
    @Published private(set) var learningSession: LearningSession?

    /// The record panel's remembered choices; "Start Recording" replays them.
    @Published var recordingSetup = RecordingSetup.load() {
        didSet { if recordingSetup != oldValue { recordingSetup.save() } }
    }
    @Published private(set) var isPaused = false
    @Published private(set) var isMicMuted = false
    /// What the recording in progress captures, for the recording bar.
    @Published private(set) var recordingSourceLabel = ""
    private var pausedTotal: TimeInterval = 0
    private var pauseStartedAt: Date?

    // MARK: - Meeting Library

    @Published var groups: [MeetingGroup] = []
    @Published var selectedGroupId: UUID?  // nil = "All Recordings"
    @Published var meetings: [Meeting] = []
    /// Meeting whose list card currently shows the inline title editor.
    @Published var renamingMeetingID: UUID?
    /// Meetings with a video/audio export in flight; menus show "Exporting…".
    @Published var exportingMeetingIDs: Set<UUID> = []
    @Published var selectedMeeting: Meeting? {
        didSet {
            let newId = selectedMeeting?.id
            let oldId = oldValue?.id
            guard newId != oldId else { return }
            if let meeting = selectedMeeting {
                tomLog("User action: selected meeting \(meeting.id.uuidString.prefix(8)) '\(meeting.title)' (state=\(meeting.state.rawValue))")
                loadMeetingInPlayer(meeting)
            } else {
                tomLog("User action: deselected meeting (previous=\(oldId?.uuidString.prefix(8) ?? "?"))")
                playerManager.stop()
            }
        }
    }
    @Published var searchQuery = ""
    @Published var ragQuery = ""
    @Published var ragAnswer = ""
    @Published var ragIsLoading = false
    @Published var ragStage: RAGStage = .idle
    @Published var ragSources: [(meetingTitle: String, meetingDate: String)] = []

    // MARK: - UI State

    @Published var showSettings = false

    /// Live transcription preview, keyed by meeting id. Populated while a
    /// meeting's primary audio stream is being transcribed (each discovered
    /// utterance appends a line) and cleared as soon as the final segments
    /// land in the DB — the transcript views switch from this preview to the
    /// real utterance list at that point.
    @Published var liveTranscripts: [UUID: String] = [:]
    /// Volatile tail of the live transcript (Parakeet rolling preview): words
    /// heard but not yet committed. Rendered after `liveTranscripts`, replaced
    /// wholesale on every update.
    @Published var liveVolatile: [UUID: String] = [:]

    /// Mirrors `ModelDownloadManager.shared.allReady`. Bridged here so views
    /// observing `AppState` re-render when models finish downloading and so
    /// the recording entry points can short-circuit on a single source of
    /// truth.
    @Published private(set) var aiModelsReady: Bool = false

    /// True when all three on-device models report Ready. Recording, voice
    /// notes, imports, and retranscribes all gate on this. Without it we'd
    /// silently kick off a pipeline that can't complete and leave meetings
    /// stuck in a failed state — or worse, trigger a multi-GB HuggingFace
    /// fetch from the inference path mid-recording.
    var canCreateMeetings: Bool { aiModelsReady && !isFinalizingRecording }

    /// True from Stop until the recorder has released the capture (a
    /// Learning session first saves its open annotation). A recording
    /// started in that window would find the recorder still busy.
    @Published private(set) var isFinalizingRecording = false

    /// Human-readable reason recording is blocked, or nil when the user can
    /// start a new meeting. Used for guard logging and intended to be
    /// surfaced inline in the recording UI. The only hard blocker is the
    /// on-device models not having finished downloading yet.
    var recordingBlockedReason: String? {
        if !aiModelsReady {
            return String(localized: "AI models aren't ready yet. Open Settings → AI Models and finish the model downloads.")
        }
        if isFinalizingRecording {
            return String(localized: "Finishing the previous recording…")
        }
        return nil
    }

    private var modelStatusCancellable: AnyCancellable?
    private var statusIconCancellable: AnyCancellable?

    // MARK: - Managers

    let recordingManager: RecordingManager
    let voiceNoteRecorder: VoiceNoteRecorder
    let transcriptionManager: TranscriptionManager
    let aiManager: AIManager
    let storageManager: StorageManager
    let embeddingManager: EmbeddingManager
    let playerManager: PlayerManager

    private let meetingDetector = MeetingDetector()

    // MARK: - Init

    init() {
        // Default the meeting-detection toggle to ON for new installs.
        if UserDefaults.standard.object(forKey: "tom.notifyMeetingStart") == nil {
            UserDefaults.standard.set(true, forKey: "tom.notifyMeetingStart")
        }

        let storage = StorageManager()
        self.storageManager = storage
        self.recordingManager = RecordingManager()
        self.voiceNoteRecorder = VoiceNoteRecorder()
        self.transcriptionManager = TranscriptionManager()
        self.aiManager = AIManager()
        self.embeddingManager = EmbeddingManager(storageManager: storage)
        self.playerManager = PlayerManager()

        // Bridge ModelDownloadManager's per-model statuses + the cloud-brain
        // preference into a single boolean we can gate on. The summary slot
        // is satisfied by *either* the on-device Qwen weights or cloud
        // brain being active (BYOK with key set), matching the same logic
        // as `ModelDownloadManager.allReady`.
        let downloads = ModelDownloadManager.shared
        let cloud = CloudBrainPreferences.shared
        self.aiModelsReady = downloads.allReady
        modelStatusCancellable = Publishers.CombineLatest4(
            downloads.$transcriptionStatus,
            downloads.$summaryStatus,
            downloads.$embeddingStatus,
            cloud.$isActive
        )
        .map { t, s, e, cloudActive in
            t.isReady && (s.isReady || cloudActive) && e.isReady
        }
        .receive(on: RunLoop.main)
        .sink { [weak self] ready in
            self?.aiModelsReady = ready
            // Meetings left mid-pipeline by a crash / force-quit can only be
            // re-queued once the models are usable — try again on every
            // readiness flip; the method no-ops after the first real run.
            if ready {
                self?.recoverInterruptedMeetings()
                self?.prewarmVoiceAIIfNeeded()
            }
        }

        // Mirror recording state onto the menu bar icon (red while live).
        statusIconCancellable = $isRecording
            .receive(on: RunLoop.main)
            .sink { recording in
                StatusItemController.shared.setRecording(recording)
            }

        loadMeetings()
        loadGroups()
        let stuckAtLaunch: Set<MeetingState> = [.recording, .transcribing, .processing]
        interruptedCandidateIds = Set(meetings.filter { stuckAtLaunch.contains($0.state) }.map(\.id))
        recoverInterruptedMeetings()
        prewarmVoiceAIIfNeeded()
        startWindowRefreshTimer()
        Self.shared = self
    }

    // MARK: - Window Discovery

    private var windowRefreshTimer: Timer?
    private var screenCapturePermissionFailures = 0

    private func startWindowRefreshTimer() {
        windowRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isRecording else { return }
                self.refreshWindows()
            }
        }
        // Also refresh immediately
        refreshWindows()
    }

    func refreshWindows() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                self.availableDisplays = content.displays

                // Capture display thumbnails via ScreenCaptureKit (replaces
                // deprecated CGDisplayCreateImage). Each shot is async, so we
                // do them sequentially in a detached Task to avoid blocking
                // the refresh flow.
                let displays = content.displays
                Task.detached {
                    var thumbs: [CGDirectDisplayID: NSImage] = [:]
                    for display in displays {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        // Capture at ~800px wide; we scale again below for the cache.
                        let aspect = Double(display.height) / Double(max(display.width, 1))
                        config.width = 800
                        config.height = max(1, Int(800.0 * aspect))
                        do {
                            let cgImage = try await SCScreenshotManager.captureImage(
                                contentFilter: filter, configuration: config
                            )
                            let maxWidth: CGFloat = 400
                            let scale = min(maxWidth / CGFloat(cgImage.width), 1.0)
                            let size = NSSize(
                                width: CGFloat(cgImage.width) * scale,
                                height: CGFloat(cgImage.height) * scale
                            )
                            thumbs[display.displayID] = NSImage(cgImage: cgImage, size: size)
                        } catch {
                            tomLog("Display thumbnail failed for \(display.displayID): \(error)")
                        }
                    }
                    let result = thumbs
                    await MainActor.run {
                        self.displayThumbnails = result
                    }
                }

                let filtered = content.windows.filter { window in
                    guard window.isOnScreen, window.frame.width > 100 else { return false }
                    guard let app = window.owningApplication else { return false }
                    let name = app.applicationName
                    guard !name.isEmpty && window.title?.isEmpty == false else { return false }
                    let bundleID = app.bundleIdentifier
                    let blocked: Set<String> = [
                        "com.apple.dock",
                        "com.apple.wallpaper",
                        "com.apple.finder",
                        "com.apple.controlcenter",
                        "com.apple.notificationcenterui",
                        "com.apple.WindowManager",
                        "com.apple.systempreferences",
                    ]
                    guard !bundleID.isEmpty,
                          bundleID != Bundle.main.bundleIdentifier,
                          !blocked.contains(bundleID) else {
                        return false
                    }
                    return true
                }
                self.availableWindows = filtered
                self.evaluateMeetingDetection(in: filtered)

                // Capture window thumbnails via ScreenCaptureKit (replaces
                // deprecated CGWindowListCreateImage). Pass the SCWindow
                // objects directly — SCContentFilter needs them, not just IDs.
                let windowsForThumbs = filtered
                Task.detached {
                    var thumbnails: [CGWindowID: NSImage] = [:]
                    for window in windowsForThumbs {
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        let config = SCStreamConfiguration()
                        // Cap at 800px wide; preserve aspect ratio.
                        let w = max(1.0, window.frame.width)
                        let h = max(1.0, window.frame.height)
                        let aspect = h / w
                        config.width = 800
                        config.height = max(1, Int(800.0 * aspect))
                        do {
                            let cgImage = try await SCScreenshotManager.captureImage(
                                contentFilter: filter, configuration: config
                            )
                            let maxWidth: CGFloat = 400
                            let scale = min(maxWidth / CGFloat(cgImage.width), 1.0)
                            let size = NSSize(
                                width: CGFloat(cgImage.width) * scale,
                                height: CGFloat(cgImage.height) * scale
                            )
                            thumbnails[window.windowID] = NSImage(cgImage: cgImage, size: size)
                        } catch {
                            tomLog("Window thumbnail failed for \(window.windowID): \(error)")
                        }
                    }
                    let result = thumbnails
                    await MainActor.run {
                        self.windowThumbnails = result
                    }
                }
            } catch {
                self.screenCapturePermissionFailures += 1
                // The window-refresh timer fires every 3s, so an unfixed
                // permission denial would spam the log indefinitely. Cap
                // both messages at the first 3 attempts.
                if self.screenCapturePermissionFailures <= 3 {
                    tomLog("Failed to get windows: \(error)")
                    tomLog("Screen capture attempt \(self.screenCapturePermissionFailures) failed — will retry. Grant permission in System Settings if needed.")
                }
            }
        }
    }

    // MARK: - Recording Flow

    func startRecording(window: SCWindow) {
        let title = window.title ?? window.owningApplication?.applicationName ?? "Meeting"
        recordingSetup.mode = .meeting
        rememberWindow(window)
        beginScreenRecording(
            meetingTitle: "Recording — \(title)",
            kind: .meeting,
            options: CaptureOptions(systemAudio: recordingSetup.meetingSystemAudio, microphone: recordingSetup.microphone),
            sourceLabel: Self.label(for: window),
            capture: { try await $0.startRecording(window: window, options: $1) }
        )
    }

    private func rememberWindow(_ window: SCWindow) {
        recordingSetup.source = .window
        recordingSetup.windowBundleID = window.owningApplication?.bundleIdentifier
        recordingSetup.windowAppName = window.owningApplication?.applicationName
        recordingSetup.windowTitle = window.title
    }

    /// "Chrome — Pricing", or whichever of app and title exists.
    private static func label(for window: SCWindow) -> String {
        [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    func startRecording(display: SCDisplay) {
        recordingSetup.mode = .meeting
        recordingSetup.source = .screen
        recordingSetup.displayID = display.displayID
        let name = displayName(for: display)
        beginScreenRecording(
            meetingTitle: "Recording — \(name)",
            kind: .meeting,
            options: CaptureOptions(systemAudio: recordingSetup.meetingSystemAudio, microphone: recordingSetup.microphone),
            sourceLabel: name,
            capture: { try await $0.startRecording(display: display, options: $1) }
        )
    }

    /// Shared start for window, screen and Learning recordings: creates the
    /// meeting, wires live transcription, starts capture off the main actor
    /// (ScreenCaptureKit can deadlock on it) and rolls everything back if
    /// capture fails. `onStarted` runs once capture is live.
    private func beginScreenRecording(
        meetingTitle: String,
        kind: MeetingKind,
        options: CaptureOptions,
        sourceLabel: String,
        capture: @escaping (RecordingManager, CaptureOptions) async throws -> Void,
        onStarted: ((UUID) -> Void)? = nil
    ) {
        guard canCreateMeetings else {
            tomLog("startRecording blocked: \(recordingBlockedReason ?? "unknown")")
            return
        }
        guard !isRecording else {
            tomLog("startRecording blocked: already recording")
            return
        }
        guard options.systemAudio || options.microphone else {
            tomLog("startRecording blocked: microphone and system audio are both off")
            return
        }
        guard microphoneReady(options.microphone, retry: { [weak self] in
            self?.beginScreenRecording(meetingTitle: meetingTitle, kind: kind, options: options, sourceLabel: sourceLabel, capture: capture, onStarted: onStarted)
        }) else { return }

        let meeting: Meeting
        do {
            meeting = try storageManager.createMeeting(title: meetingTitle, kind: kind)
        } catch {
            tomLog("Failed to create meeting: \(error)")
            return
        }
        currentMeetingId = meeting.id
        currentRecordingKind = kind
        meetings.insert(meeting, at: 0)

        let session = makeScreenLiveSession(meetingId: meeting.id, options: options, label: kind == .learning ? "Me" : "Speaker")
        recordingManager.streamingSession = session
        dropAIModelsForRecording(keepVoiceAI: session != nil)

        // Stop window refresh to avoid concurrent SCShareableContent calls
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil

        resetRecordingControls()
        recordingSourceLabel = sourceLabel
        isRecording = true
        currentTranscript = ""
        recordingStartTime = Date()

        let recorder = recordingManager
        let meetingId = meeting.id
        Task.detached {
            do {
                try await capture(recorder, options)
            } catch {
                tomLog("Failed to start recording: \(error)")
                await MainActor.run { self.abortStart(meetingId: meetingId) }
                return
            }
            await MainActor.run {
                guard self.isRecording, self.currentMeetingId == meetingId else { return }
                onStarted?(meetingId)
            }
        }
    }

    /// Live transcription for whichever audio sources the recording has:
    /// both mixed into one stream, or the one that's on.
    private func makeScreenLiveSession(meetingId: UUID, options: CaptureOptions, label: String) -> StreamingTranscriptionSession? {
        switch (options.systemAudio, options.microphone) {
        case (true, true):
            return makeLiveSession(meetingId: meetingId, sources: ["mixed": label], primary: "mixed", mixing: ["system", "mic"])
        case (true, false):
            return makeLiveSession(meetingId: meetingId, sources: ["system": label], primary: "system")
        default:
            return makeLiveSession(meetingId: meetingId, sources: ["mic": label], primary: "mic")
        }
    }

    /// Without microphone permission macOS hands the app silence, so a
    /// recording that uses the mic checks first. Undecided: asks, and
    /// `retry` starts the recording once granted. Refused: explains where to
    /// turn it on. Returns true when recording can start now.
    private func microphoneReady(_ needed: Bool, retry: @escaping @MainActor () -> Void) -> Bool {
        guard needed else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            tomLog("Microphone permission not determined — asking")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    tomLog("Microphone permission \(granted ? "granted" : "denied")")
                    if granted { retry() } else { Self.showMicrophoneDenied() }
                }
            }
            return false
        default:
            tomLog("startRecording blocked: microphone permission denied")
            Self.showMicrophoneDenied()
            return false
        }
    }

    private static func showMicrophoneDenied() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Microphone access is off")
        alert.informativeText = String(localized: "TOM needs the microphone to record your voice. Turn it on for TOM in System Settings › Privacy & Security › Microphone, or switch the microphone off in the record panel to record system audio only.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Capture never started: undo the placeholder meeting and state.
    private func abortStart(meetingId: UUID) {
        isRecording = false
        recordingStartTime = nil
        currentMeetingId = nil
        currentRecordingKind = .meeting
        recordingManager.streamingSession = nil
        liveSession = nil
        liveTranscripts.removeValue(forKey: meetingId)
        liveVolatile.removeValue(forKey: meetingId)
        resetRecordingControls()
        updateMeeting(id: meetingId) { $0.state = .failed }
        startWindowRefreshTimer()
    }

    /// "Built-in Display", "External Display" or "External Display N".
    func displayName(for display: SCDisplay) -> String {
        if CGDisplayIsBuiltin(display.displayID) != 0 {
            return "Built-in Display"
        }
        let externals = availableDisplays.filter { CGDisplayIsBuiltin($0.displayID) == 0 }
        if externals.count > 1, let idx = externals.firstIndex(where: { $0.displayID == display.displayID }) {
            return "External Display \(idx + 1)"
        }
        return "External Display"
    }

    // MARK: - Feedback Flow

    /// Starts a Feedback session on a whole display: a recording of the
    /// narrated review plus the annotation overlay. Annotations and their
    /// screenshots are saved as they're made; the transcript is merged with
    /// them afterwards (see `LearningReview`).
    func startFeedback(display: SCDisplay) {
        tomLog("User action: Start Feedback session (display=\(display.displayID))")
        recordingSetup.mode = .feedback
        recordingSetup.source = .screen
        recordingSetup.displayID = display.displayID
        beginFeedback(title: displayName(for: display), display: display, window: nil) {
            try await $0.startRecording(display: display, options: $1)
        }
    }

    /// Feedback on one window: the video is that window alone, the overlay
    /// covers the display it's on, and screenshots show just the window.
    func startFeedback(window: SCWindow) {
        tomLog("User action: Start Feedback session (window=\(window.windowID))")
        guard let display = display(containing: window) else {
            tomLog("Feedback: no display for window \(window.windowID)")
            return
        }
        recordingSetup.mode = .feedback
        rememberWindow(window)
        beginFeedback(title: Self.label(for: window), display: display, window: window) {
            try await $0.startRecording(window: window, options: $1)
        }
    }

    private func beginFeedback(
        title: String,
        display: SCDisplay,
        window: SCWindow?,
        capture: @escaping (RecordingManager, CaptureOptions) async throws -> Void
    ) {
        let recorder = recordingManager
        let storage = storageManager
        beginScreenRecording(
            meetingTitle: "Feedback — \(title)",
            kind: .learning,
            options: CaptureOptions(systemAudio: recordingSetup.feedbackSystemAudio, microphone: recordingSetup.microphone),
            sourceLabel: title,
            capture: capture
        ) { [weak self] meetingId in
            guard let self else { return }
            guard let learning = LearningSession(
                meetingId: meetingId, display: display, window: window,
                recordingStart: recorder.startedAt ?? Date(), storage: storage,
                pausedDuration: { [weak self] in self?.pausedDuration() ?? 0 },
                onStop: { [weak self] in self?.stopRecording() }
            ) else {
                tomLog("Feedback: no NSScreen for display \(display.displayID); recording without overlay")
                return
            }
            self.learningSession = learning
            Task {
                // A window recording never contains the HUD.
                if let hud = await learning.start(), window == nil {
                    await recorder.excludeFromRecording([hud])
                }
            }
        }
    }

    /// The display showing most of `window`.
    private func display(containing window: SCWindow) -> SCDisplay? {
        let area = { (d: SCDisplay) -> CGFloat in
            let overlap = d.frame.intersection(window.frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return availableDisplays.max { area($0) < area($1) }.flatMap { area($0) > 0 ? $0 : nil } ?? lastDisplay
    }

    // MARK: - Recording Controls

    /// The remembered display, or the main one.
    var lastDisplay: SCDisplay? {
        availableDisplays.first { $0.displayID == recordingSetup.displayID }
            ?? availableDisplays.first { CGDisplayIsMain($0.displayID) != 0 }
            ?? availableDisplays.first
    }

    /// The remembered window: same app and title, else that app's first.
    var lastWindow: SCWindow? {
        guard let bundle = recordingSetup.windowBundleID else { return nil }
        let candidates = availableWindows.filter { $0.owningApplication?.bundleIdentifier == bundle }
        return candidates.first { $0.title == recordingSetup.windowTitle } ?? candidates.first
    }

    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            pausedTotal += Date().timeIntervalSince(pauseStartedAt ?? Date())
            pauseStartedAt = nil
        } else {
            pauseStartedAt = Date()
        }
        isPaused.toggle()
        if currentRecordingKind == .voiceNote {
            voiceNoteRecorder.isPaused = isPaused
        } else {
            recordingManager.setPaused(isPaused)
        }
        tomLog("User action: \(isPaused ? "Pause" : "Resume") recording")
    }

    func toggleMicMute() {
        guard isRecording, currentRecordingKind != .voiceNote else { return }
        isMicMuted.toggle()
        recordingManager.setMicMuted(isMicMuted)
        tomLog("User action: Mic \(isMicMuted ? "muted" : "unmuted")")
    }

    /// Paused time so far, including a pause in progress.
    func pausedDuration(at date: Date = Date()) -> TimeInterval {
        pausedTotal + (pauseStartedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    /// Recording time shown in timers: wall time minus pauses.
    func recordingElapsed(at date: Date) -> TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return max(0, date.timeIntervalSince(start) - pausedDuration(at: date))
    }

    private func resetRecordingControls() {
        isPaused = false
        isMicMuted = false
        pausedTotal = 0
        pauseStartedAt = nil
        recordingSourceLabel = ""
    }

    func stopRecording() {
        guard isRecording else { return }
        tomLog("User action: Stop recording (kind=\(currentRecordingKind.rawValue), elapsed=\(Int(Date().timeIntervalSince(recordingStartTime ?? Date())))s)")

        if currentRecordingKind == .voiceNote {
            stopVoiceNote()
            return
        }

        isRecording = false

        let meetingId = currentMeetingId
        let startTime = recordingStartTime ?? Date()
        let session = liveSession
        let kind = currentRecordingKind
        let learning = learningSession
        currentMeetingId = nil
        currentRecordingKind = .meeting
        recordingStartTime = nil
        liveSession = nil
        learningSession = nil
        resetRecordingControls()

        // Restart window refresh timer
        startWindowRefreshTimer()

        let recorder = recordingManager
        let transcriber = transcriptionManager
        let ai = aiManager
        let embedder = embeddingManager
        let storage = storageManager
        isFinalizingRecording = true

        // File finalisation (ScreenCaptureKit stop + writing the mp4 to disk)
        // runs immediately and is NOT inference-bound, so it doesn't share the
        // queue with retranscribes / imports. Once the file is on disk, the
        // post-recording pipeline is enqueued so it serialises with anything
        // else the user has triggered.
        Task.detached {
            // Close an open annotation (its screenshot needs the overlay)
            // before capture stops.
            await learning?.end()
            let result: RecordingResult
            do {
                defer { Task { @MainActor in self.isFinalizingRecording = false } }
                result = try await recorder.stopRecording()
                tomLog("Recording saved: \(result.videoURL.path)")
                if let mic = result.micURL { tomLog("Mic saved: \(mic.path)") }
            } catch {
                tomLog("Failed to stop recording: \(error)")
                if let meetingId {
                    await MainActor.run { self.updateMeetingState(id: meetingId, state: .failed) }
                }
                return
            }

            let fileURL = result.videoURL
            let micURL = result.micURL

            guard let meetingId else { return }

            // The video stops growing while the screen is static, so the mic
            // (when present) is the better measure of how long it ran.
            let asset = AVURLAsset(url: fileURL)
            let videoSeconds = (try? await asset.load(.duration).seconds) ?? Date().timeIntervalSince(startTime)
            var micSeconds: TimeInterval = 0
            if let micURL, let seconds = try? await AVURLAsset(url: micURL).load(.duration).seconds {
                micSeconds = seconds
            }
            let duration: TimeInterval = max(videoSeconds, micSeconds)
            let relativePath = fileURL.lastPathComponent
            tomLog("Duration: \(Int(duration))s")

            await MainActor.run {
                self.updateMeeting(id: meetingId) { meeting in
                    meeting.recordingPath = relativePath
                    meeting.duration = duration
                    meeting.state = .transcribing
                }
                ProcessingQueue.shared.enqueue(meetingId: meetingId) { [weak self] in
                    // Drain the live session first: flushes the un-transcribed
                    // tail and returns the full segment list, or nil if
                    // streaming failed (→ classic full-file transcription).
                    let streamed = await session?.finish()
                    await self?.processRecording(
                        meetingId: meetingId,
                        videoURL: fileURL,
                        micURL: micURL,
                        kind: kind,
                        transcriber: transcriber,
                        ai: ai,
                        embedder: embedder,
                        storage: storage,
                        streamedOutcome: streamed
                    )
                }
            }
        }
    }

    // MARK: - Voice Note Flow

    /// Start a mic-only voice note recording. Same post-processing pipeline
    /// (Whisper → embeddings → AI) as a meeting; just one stream, labeled "Me".
    func startVoiceNote() {
        tomLog("User action: Start Voice Note")
        guard canCreateMeetings else {
            tomLog("startVoiceNote blocked: \(recordingBlockedReason ?? "unknown")")
            return
        }
        guard !isRecording else {
            tomLog("startVoiceNote blocked: already recording")
            return
        }
        guard microphoneReady(true, retry: { [weak self] in self?.startVoiceNote() }) else { return }

        let meetingTitle = "Voice Note"
        let createdMeetingId: UUID
        do {
            let meeting = try storageManager.createMeeting(title: meetingTitle, kind: .voiceNote)
            createdMeetingId = meeting.id
            currentMeetingId = meeting.id
            currentRecordingKind = .voiceNote
            meetings.insert(meeting, at: 0)
        } catch {
            tomLog("Failed to create voice note meeting: \(error)")
            return
        }

        let session = makeLiveSession(
            meetingId: createdMeetingId,
            sources: ["mic": "Me"],
            primary: "mic"
        )
        voiceNoteRecorder.streamingSession = session
        dropAIModelsForRecording(keepVoiceAI: session != nil)

        recordingSetup.mode = .voiceNote
        resetRecordingControls()
        recordingSourceLabel = String(localized: "Voice note")
        isRecording = true
        currentTranscript = ""
        recordingStartTime = Date()

        do {
            _ = try voiceNoteRecorder.startRecording()
        } catch {
            tomLog("Failed to start voice note: \(error)")
            // Roll back the placeholder meeting so the library doesn't show an empty card.
            isRecording = false
            currentRecordingKind = .meeting
            currentMeetingId = nil
            recordingStartTime = nil
            voiceNoteRecorder.streamingSession = nil
            liveSession = nil
            liveTranscripts.removeValue(forKey: createdMeetingId)
            liveVolatile.removeValue(forKey: createdMeetingId)
            try? storageManager.deleteMeeting(id: createdMeetingId)
            meetings.removeAll { $0.id == createdMeetingId }
            NotificationCenter.default.post(name: .recordingDidFail, object: error)
        }
    }

    private func stopVoiceNote() {
        let meetingId = currentMeetingId
        let elapsed = recordingElapsed(at: Date())
        let session = liveSession
        resetRecordingControls()

        isRecording = false
        currentMeetingId = nil
        currentRecordingKind = .meeting
        recordingStartTime = nil
        liveSession = nil

        let url = voiceNoteRecorder.stopRecording()

        guard let meetingId else { return }

        guard let url else {
            tomLog("Voice note stopped with no audio file (mic empty / not started)")
            liveTranscripts.removeValue(forKey: meetingId)
            liveVolatile.removeValue(forKey: meetingId)
            updateMeeting(id: meetingId) { $0.state = .failed }
            return
        }

        let duration = elapsed
        let relativePath = url.lastPathComponent

        updateMeeting(id: meetingId) { meeting in
            meeting.recordingPath = relativePath
            meeting.duration = duration
            meeting.state = .transcribing
        }

        let transcriber = transcriptionManager
        let ai = aiManager
        let embedder = embeddingManager
        let storage = storageManager

        ProcessingQueue.shared.enqueue(meetingId: meetingId) { [weak self] in
            let streamed = await session?.finish()
            await self?.processRecording(
                meetingId: meetingId,
                videoURL: url,           // wav file — Whisper accepts it directly
                micURL: nil,
                kind: .voiceNote,
                transcriber: transcriber,
                ai: ai,
                embedder: embedder,
                storage: storage,
                streamedOutcome: streamed
            )
        }
    }

    // MARK: - Import Recording

    /// Imports a user-supplied audio or video file (.mp4 / .m4a / .mp3 / .wav /
    /// .mov), copies it into the recordings dir under a fresh UUID, then runs
    /// the same post-recording pipeline as a live meeting — minus the mic mux
    /// step (single audio source, no separate mic.wav).
    ///
    /// Multi-file selection from the Open Panel works because `ProcessingQueue`
    /// serialises the inference pipelines: dropping in 5 files spawns 5 entries
    /// in the queue and the first one starts immediately while the rest show
    /// the "Queued" badge in the meeting list.
    func importRecording(from sourceURL: URL) {
        tomLog("User action: Import recording — \(sourceURL.lastPathComponent)")
        guard canCreateMeetings else {
            tomLog("importRecording blocked: \(recordingBlockedReason ?? "unknown")")
            return
        }
        // We allow imports while a live recording is in progress; the queue
        // takes care of running them one at a time after the recording's own
        // post-processing completes.

        let supportedExtensions: Set<String> = ["mp4", "m4a", "mp3", "wav", "mov"]
        let ext = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            tomLog("importRecording: unsupported extension '\(ext)'")
            return
        }

        let title = sourceURL.deletingPathExtension().lastPathComponent
        let createdMeeting: Meeting
        do {
            createdMeeting = try storageManager.createMeeting(title: title, kind: .imported)
        } catch {
            tomLog("importRecording: failed to create meeting: \(error)")
            return
        }
        let meetingId = createdMeeting.id
        meetings.insert(createdMeeting, at: 0)

        let destDir = RecordingManager.recordingsDirectory
        let destURL = destDir.appendingPathComponent("\(meetingId.uuidString).\(ext)")
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            tomLog("importRecording: copy failed: \(error)")
            try? storageManager.deleteMeeting(id: meetingId)
            meetings.removeAll { $0.id == meetingId }
            return
        }

        let relativePath = destURL.lastPathComponent
        updateMeeting(id: meetingId) { meeting in
            meeting.recordingPath = relativePath
            meeting.state = .transcribing
        }

        let transcriber = transcriptionManager
        let ai = aiManager
        let embedder = embeddingManager
        let storage = storageManager

        ProcessingQueue.shared.enqueue(meetingId: meetingId) { [weak self] in
            // Read duration off the main actor — AVURLAsset.load() blocks on disk.
            let asset = AVURLAsset(url: destURL)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard let self else { return }
            await MainActor.run {
                self.updateMeeting(id: meetingId) { $0.duration = duration }
            }
            tomLog("Imported \(destURL.lastPathComponent) (\(Int(duration))s)")

            await self.processRecording(
                meetingId: meetingId,
                videoURL: destURL,
                micURL: nil,
                kind: .imported,
                transcriber: transcriber,
                ai: ai,
                embedder: embedder,
                storage: storage
            )
        }
    }

    // MARK: - Retranscribe (dev)

    /// Re-runs the transcription + AI pipeline against a meeting's existing
    /// recording on disk. Used by the dev-mode context menu to recover meetings
    /// whose initial pipeline failed.
    ///
    /// Multiple retranscribes (selecting 4 meetings and clicking Retranscribe
    /// on each) are coalesced through `ProcessingQueue` so the inference
    /// pipelines run one at a time instead of forking N concurrent Whisper +
    /// Qwen runs that would saturate the GPU and exhaust unified memory.
    func retranscribe(_ meeting: Meeting) {
        tomLog("User action: retranscribe meeting \(meeting.id.uuidString.prefix(8)) '\(meeting.title)' (kind=\(meeting.kind.rawValue))")
        guard !meeting.recordingPath.isEmpty else {
            tomLog("retranscribe: meeting has no recording_path")
            return
        }
        let videoURL = RecordingManager.recordingsDirectory.appendingPathComponent(meeting.recordingPath)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            tomLog("retranscribe: recording file missing at \(videoURL.path)")
            return
        }

        // Voice notes are single-stream; meetings may have a sibling .mic.wav.
        let micURL = Self.micSidecarURL(for: meeting, videoURL: videoURL)

        let meetingId = meeting.id
        let kind = meeting.kind
        let transcriber = transcriptionManager
        let ai = aiManager
        let embedder = embeddingManager
        let storage = storageManager

        // Wipe every AI-derived artifact before the pipeline runs again so
        // a partial failure (transcription succeeds but summary fails, say)
        // can't leave the meeting holding the previous run's title +
        // summary alongside the new transcript. Order matters: clear the
        // in-memory + meeting row first so the UI shows a clean
        // "Re-transcribing…" placeholder, then flush the related tables.
        updateMeeting(id: meetingId) { meeting in
            meeting.transcript = nil
            meeting.summary = nil
            if !meeting.titleIsCustom {
                meeting.title = String(localized: "Re-transcribing…")
            }
            // Leave state as-is here (or .transcribing if you prefer); the
            // queue badge takes over until the worker picks the job up.
            meeting.state = .transcribing
        }

        ProcessingQueue.shared.enqueue(meetingId: meetingId) { [weak self] in
            do {
                try storage.saveTranscriptSegments([], meetingId: meetingId)
                try storage.deleteEmbeddings(meetingId: meetingId)
            } catch {
                tomLog("retranscribe: failed to clear prior state: \(error)")
            }
            await self?.processRecording(
                meetingId: meetingId,
                videoURL: videoURL,
                micURL: micURL,
                kind: kind,
                transcriber: transcriber,
                ai: ai,
                embedder: embedder,
                storage: storage
            )
        }
    }

    // MARK: - Interrupted-Meeting Recovery

    /// Set once the re-queue pass has actually run so a later model-status
    /// flap doesn't re-enqueue meetings that are already processing.
    private var recoveredInterrupted = false

    /// Meetings that were ALREADY stuck when the app launched — the only ones
    /// recovery may ever touch. Captured once in `init`. Without this frozen
    /// snapshot, a model-status re-emission during a live pipeline could see
    /// the in-flight meeting (state .transcribing, no longer "queued") as
    /// stuck and re-enqueue it — producing a second, redundant transcription
    /// run right after the first one finished.
    private var interruptedCandidateIds: Set<UUID> = []

    /// Meetings persisted mid-pipeline (`.recording` / `.transcribing` /
    /// `.processing`) at launch can never finish on their own — the closures
    /// driving them died with the previous process — so without this sweep
    /// they sit on "Transcribing" forever. Recordings still on disk are
    /// re-queued through the normal pipeline (title and any partial artifacts
    /// preserved); meetings whose file never made it to disk are marked
    /// failed. Re-queueing waits for `aiModelsReady`; the failure marking
    /// doesn't need models and runs immediately.
    private func recoverInterruptedMeetings() {
        let stuckStates: Set<MeetingState> = [.recording, .transcribing, .processing]
        let stuck = meetings.filter {
            interruptedCandidateIds.contains($0.id)
                && stuckStates.contains($0.state)
                && !ProcessingQueue.shared.isQueued($0.id)
                && ProcessingQueue.shared.activeMeetingId != $0.id
        }
        guard !stuck.isEmpty else {
            recoveredInterrupted = true
            return
        }

        var recoverable: [Meeting] = []
        for meeting in stuck {
            let url = RecordingManager.recordingsDirectory.appendingPathComponent(meeting.recordingPath)
            if meeting.recordingPath.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
                tomLog("Recovery: meeting \(meeting.id.uuidString.prefix(8)) stuck in \(meeting.state.rawValue) with no recording file — marking failed")
                updateMeeting(id: meeting.id) { $0.state = .failed }
            } else {
                recoverable.append(meeting)
            }
        }

        guard !recoverable.isEmpty else {
            recoveredInterrupted = true
            return
        }
        guard aiModelsReady, !recoveredInterrupted else { return }
        recoveredInterrupted = true

        for meeting in recoverable {
            tomLog("Recovery: meeting \(meeting.id.uuidString.prefix(8)) '\(meeting.title)' stuck in \(meeting.state.rawValue) — re-queuing pipeline")
            let videoURL = RecordingManager.recordingsDirectory.appendingPathComponent(meeting.recordingPath)
            let micURL = Self.micSidecarURL(for: meeting, videoURL: videoURL)
            let meetingId = meeting.id
            let kind = meeting.kind
            let transcriber = transcriptionManager
            let ai = aiManager
            let embedder = embeddingManager
            let storage = storageManager

            updateMeeting(id: meetingId) { $0.state = .transcribing }
            ProcessingQueue.shared.enqueue(meetingId: meetingId) { [weak self] in
                await self?.processRecording(
                    meetingId: meetingId,
                    videoURL: videoURL,
                    micURL: micURL,
                    kind: kind,
                    transcriber: transcriber,
                    ai: ai,
                    embedder: embedder,
                    storage: storage
                )
            }
        }
    }

    /// Resolves the optional `.mic.wav` sidecar next to a meeting's recording.
    /// Voice notes are single-stream and never have one.
    private static func micSidecarURL(for meeting: Meeting, videoURL: URL) -> URL? {
        guard meeting.kind != .voiceNote else { return nil }
        let candidate = videoURL.deletingPathExtension().appendingPathExtension("mic.wav")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Shared Post-Recording Pipeline

    /// Whisper + AI + embeddings pipeline used by both live recording and
    /// retranscribe. Runs off the main actor; hops back via `MainActor.run` for
    /// state updates.
    private nonisolated func processRecording(
        meetingId: UUID,
        videoURL: URL,
        micURL: URL?,
        kind: MeetingKind,
        transcriber: TranscriptionManager,
        ai: AIManager,
        embedder: EmbeddingManager,
        storage: StorageManager,
        streamedOutcome: TranscriptionOutcome? = nil
    ) async {
        // Segments already produced live during the recording? Then the
        // whole full-file stage (and the m4a extraction that feeds it) is
        // skipped below — the audio was transcribed while it was captured.
        var liveSegments = (streamedOutcome?.segments.isEmpty == false) ? streamedOutcome : nil

        // Whisper re-transcription: the live (Parakeet) transcript was the
        // instant draft; discard it and run the full-file pass pinned to
        // Whisper large-v3-turbo for archival accuracy. The full-file path
        // applies every hallucination filter, same as the live path.
        let effectiveTranscriber: TranscriptionManager
        if WhisperRetranscription.isEnabled {
            if let live = liveSegments {
                tomLog("Pipeline: Whisper re-transcription ON — discarding \(live.segments.count) live segments, running full Whisper pass")
                liveSegments = nil
            }
            effectiveTranscriber = TranscriptionManager(service: WhisperKitTranscriber.shared)
        } else {
            effectiveTranscriber = transcriber
        }

        // Local WhisperKit accepts most audio formats directly — we still
        // extract m4a from the mp4 because the AppState pipeline uses the
        // extracted file as a clean "Other" source even after the mp4 has
        // been mixed for playback. Voice notes are already mic-only audio
        // files; we use them directly.
        let extractedM4A = videoURL.deletingPathExtension().appendingPathExtension("m4a")
        let systemAudioURL: URL
        let extractedSysExists: Bool
        // Screen recordings made without system audio have a silent video
        // until the mic is muxed in below.
        var videoHasAudio = true
        if kind == .learning || kind == .meeting, let tracks = try? await AVURLAsset(url: videoURL).loadTracks(withMediaType: .audio) {
            videoHasAudio = !tracks.isEmpty
        }
        // Nothing to transcribe (mic gave no audio and system audio was
        // off): keep the recording, and a Feedback session's annotations,
        // rather than failing it.
        if !videoHasAudio && micURL == nil {
            tomLog("Pipeline: recording has no audio — skipping transcription")
            await MainActor.run {
                self.liveTranscripts.removeValue(forKey: meetingId)
                self.liveVolatile.removeValue(forKey: meetingId)
                self.updateMeeting(id: meetingId) { $0.state = .completed }
            }
            return
        }
        if kind == .voiceNote || kind == .imported || liveSegments != nil || !videoHasAudio {
            systemAudioURL = videoHasAudio ? videoURL : (micURL ?? videoURL)
            extractedSysExists = false
            if liveSegments == nil { tomLog("Using audio file directly for transcription") }
        } else {
            do {
                try await Self.exportAudioOnly(from: videoURL, to: extractedM4A)
            } catch {
                tomLog("Audio extraction failed: \(error)")
                await MainActor.run { self.updateMeeting(id: meetingId) { $0.state = .failed } }
                return
            }
            let audioSize = (try? FileManager.default.attributesOfItem(atPath: extractedM4A.path)[.size] as? Int) ?? 0
            guard audioSize > 0 else {
                tomLog("Audio extraction produced empty file — marking failed")
                await MainActor.run { self.updateMeeting(id: meetingId) { $0.state = .failed } }
                return
            }
            tomLog("Audio extracted: \(extractedM4A.lastPathComponent) (\(audioSize / 1024)KB)")
            systemAudioURL = extractedM4A
            extractedSysExists = true
        }

        // Mix mic into the mp4 for playback. Done AFTER sys-audio extraction so
        // the extract above stays a clean "Other" source. Failure is non-fatal —
        // the recording still has system audio and a mic.wav sidecar. Idempotent
        // via a `.mic-muxed` marker so retranscribe doesn't re-mux.
        var transcriptionAudioURL = systemAudioURL
        if kind != .voiceNote, let micURL {
            do {
                try await AudioMuxer.muxMicIntoVideo(
                    videoURL: videoURL,
                    micURL: micURL,
                    preExtractedSysAudio: extractedSysExists ? extractedM4A : nil
                )
                // Transcribe one mixed stream (mic + system) rather than two
                // separate ones: a voice that reaches both sources (speakers,
                // sidetone, browser monitoring) would otherwise be transcribed
                // twice under two speaker labels, while headphone users still
                // keep their own words via the mic half of the mix.
                transcriptionAudioURL = videoURL
            } catch {
                tomLog("Mic-into-video mux failed (continuing without mux): \(error)")
            }
        }

        do {
            await MainActor.run { self.updateMeeting(id: meetingId) { $0.state = .transcribing } }

            let segments: [TranscriptSegment]
            let detectedLanguage: String?

            if let liveSegments {
                // Everything was transcribed live while recording; the tail
                // was flushed in finish(). Segments arrive labelled, folded,
                // and chronologically ordered.
                segments = liveSegments.segments
                detectedLanguage = liveSegments.language
                tomLog("Pipeline: using \(segments.count) live-transcribed segments — skipping full-file Whisper pass")
            } else {
                tomLog("Starting transcription...")
                // One stream, one label. Voice notes and Learning
                // sessions: the user narrating → "Me".
                // Meetings: mic + system mixed (see mux above) → "Speaker";
                // the user can rename it via the per-meeting alias UI.
                // Imports: the file's own audio → "Speaker".
                //
                // Every utterance the decoder discovers is appended to
                // `liveTranscripts[meetingId]` so the transcript views show
                // text while the file is still being processed.
                let liveUpdate: @Sendable (String) -> Void = { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let existing = self.liveTranscripts[meetingId] ?? ""
                        self.liveTranscripts[meetingId] = existing.isEmpty ? text : existing + "\n" + text
                    }
                }
                // Register the preview entry *before* transcription starts. The
                // empty string renders as "loading the model…" in the UI — the
                // cold load can take minutes (first run after an update recompiles
                // the CoreML graph), and without this the user stares at a dead
                // spinner the whole time wondering if anything is happening.
                await MainActor.run { self.liveTranscripts[meetingId] = "" }
                let outcome = try await effectiveTranscriber.transcribeFullRecording(
                    fileURL: transcriptionAudioURL,
                    onSegmentDiscovered: liveUpdate
                )
                detectedLanguage = outcome.language

                let label = (kind == .voiceNote || kind == .learning) ? "Me" : "Speaker"
                segments = outcome.segments.map {
                    TranscriptSegment(startTime: $0.startTime, endTime: $0.endTime, speaker: label, text: $0.text, words: $0.words)
                }
            }
            // Resolve speaker labels through the meeting's alias map so any prior
            // user renames flow into the AI summary and embeddings on retranscribe.
            // Stored transcript segments keep raw labels so the rename is reversible.
            let aliases = (try? storage.fetchMeeting(id: meetingId)?.speakerAliases) ?? [:]
            let fullTranscript = segments
                .map { "\(aliases[$0.speaker] ?? $0.speaker): \($0.text)" }
                .joined(separator: "\n")
            tomLog("Merged \(segments.count) segments (kind=\(kind.rawValue), live=\(liveSegments != nil))")

            try storage.saveTranscriptSegments(segments, meetingId: meetingId)

            await MainActor.run {
                self.updateMeeting(id: meetingId) { meeting in
                    meeting.transcript = fullTranscript
                    meeting.state = .processing
                }
                // Final segments are in the DB — swap the live preview for
                // the real utterance list, and push the segments into the
                // player if this meeting is on screen so the transcript
                // appears without reselecting (or ⌘R).
                self.liveTranscripts.removeValue(forKey: meetingId)
                self.liveVolatile.removeValue(forKey: meetingId)
                self.refreshPlayerAfterTranscription(meetingId: meetingId, segments: segments)
            }

            tomLog("Transcription complete (\(fullTranscript.count) chars). Running AI...")

            // Substance gate: refuse to call the LLM on filler. A 20-char threshold
            // lets through "okay okay hello hello" which makes the title prompt
            // hallucinate a meeting topic. Require both a minimum length AND enough
            // unique substantive tokens.
            let trimmed = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed
                .lowercased()
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                .filter { !$0.isEmpty && $0 != "me" && $0 != "speaker" }
            let uniqueWords = Set(words)
            guard trimmed.count >= 60, uniqueWords.count >= 12 else {
                tomLog("Transcript too thin (\(trimmed.count) chars, \(uniqueWords.count) unique words). Skipping AI.")
                await MainActor.run { self.updateMeeting(id: meetingId) { $0.state = .completed } }
                return
            }

            // Free Whisper's CoreML weights before Qwen prefills its KV cache.
            // On a 2 h transcript (~30K tokens) Qwen's prefill needs several
            // GB of unified memory; with Whisper still resident from
            // transcription, 16 GB Macs hit the OOM cliff and the process
            // is jetsam-killed. Unloading here frees ~1.5–2 GB right when
            // the LLM needs it. Whisper re-loads on the next meeting (~30 s
            // cold start), which is acceptable because the queue runs jobs
            // serially.
            await transcriber.unload()
            tomLog("Pipeline: dropping Voice AI before Think AI prefill")

            // Resolve the ISO code Whisper detected into an English language
            // name ("ro" → "Romanian") for explicit substitution in the
            // summary / title / chunk-extract prompts. Smaller models like
            // Qwen 3 4B sometimes guess the wrong language from short
            // transcripts; passing it explicitly removes the guessing.
            let resolvedLanguage = TranscriptionOutcome(segments: [], language: detectedLanguage).languageName
            tomLog("Pipeline: passing language hint to AI — \(resolvedLanguage ?? "unknown")")
            let result = try await ai.processMeeting(transcript: fullTranscript, kind: kind, language: resolvedLanguage)

            await MainActor.run {
                self.updateMeeting(id: meetingId) { meeting in
                    // Empty AI responses mean "no substantive content" — keep the
                    // default title/summary instead of overwriting with junk.
                    meeting.applyAITitle(result.title)
                    if !result.summary.isEmpty {
                        meeting.summary = result.summary
                    }
                    meeting.state = .completed
                }
            }

            // Drop Qwen before the embedder runs. ~2.4 GB freed; embedder is
            // tiny so it has plenty of room. Next inference (next meeting,
            // or Ask) re-loads from the on-disk cache (~10–15 s cold start).
            await ai.unload()
            tomLog("Pipeline: dropping Think AI after summary")

            tomLog("Pipeline: summary done, generating embeddings…")

            do {
                try await embedder.embedAndStore(transcript: fullTranscript, meetingId: meetingId)
                tomLog("Pipeline: embeddings stored")
            } catch {
                tomLog("Pipeline: embeddings failed (non-fatal): \(error)")
            }

            // Drop the embedder so the meeting pipeline returns to baseline
            // RAM. The next meeting re-loads it; the next Ask re-loads it.
            // Cold-start is a few seconds — cheaper than holding ~120 MB
            // resident between meetings.
            await embedder.unload()
            tomLog("Pipeline: dropping Search AI after embeddings")

            tomLog("Meeting processing complete!")

            await MainActor.run {
                let title = self.meetings.first(where: { $0.id == meetingId })?.title ?? "Meeting"
                self.sendNotification(title: String(localized: "Recording Ready"), body: String(localized: "\(title) — Summary and transcript are ready"), meetingId: meetingId)
            }

        } catch {
            tomLog("Processing failed: \(error)")
            await MainActor.run {
                self.liveTranscripts.removeValue(forKey: meetingId)
                self.liveVolatile.removeValue(forKey: meetingId)
                self.updateMeeting(id: meetingId) { $0.state = .failed }
                let title = self.meetings.first(where: { $0.id == meetingId })?.title ?? "Meeting"
                self.sendNotification(title: String(localized: "Processing Failed"), body: String(localized: "\(title) — Could not generate summary. The on-device model may still be downloading; try again in a moment."), meetingId: meetingId)
            }
        }
    }

    // MARK: - Transcription Helpers

    // MARK: - Audio Export

    /// Extract audio-only m4a from an mp4 using AVAssetExportSession with explicit
    /// status checking. The deprecated zero-arg `await export()` returns without
    /// writing a file on macOS 26 in some cases without setting `error`, so we use
    /// the callback API and treat anything other than `.completed` as a failure.
    private static func exportAudioOnly(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.invalidAudioBuffer
        }
        session.outputURL = destination
        session.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return
        case .failed, .cancelled:
            throw session.error ?? NSError(
                domain: "TOM.AudioExport",
                code: Int(session.status.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Audio export status \(session.status.rawValue)"]
            )
        default:
            throw NSError(
                domain: "TOM.AudioExport",
                code: Int(session.status.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Audio export ended in unexpected status \(session.status.rawValue)"]
            )
        }
    }

    // MARK: - Helpers

    func loadMeetingInPlayer(_ meeting: Meeting) {
        playerManager.stop()                          // always stop prior audio before loading (or bailing out)
        guard !meeting.recordingPath.isEmpty else { return }
        let url = RecordingManager.recordingsDirectory.appendingPathComponent(meeting.recordingPath)
        let storage = storageManager
        let meetingId = meeting.id
        let hasVideo = meeting.hasVideo
        Task.detached {
            let segments = (try? storage.fetchTranscriptSegments(meetingId: meetingId)) ?? []
            await MainActor.run {
                guard self.selectedMeeting?.id == meetingId else { return }
                self.playerManager.load(url: url, segments: segments, hasVideo: hasVideo)
            }
        }
    }

    /// Pushes freshly-saved transcript segments into the on-screen player the
    /// moment the pipeline finishes. Without this the player keeps the (empty)
    /// segment list it loaded when the meeting was selected mid-transcription,
    /// and the transcript only appears after reselecting the meeting.
    private func refreshPlayerAfterTranscription(meetingId: UUID, segments: [TranscriptSegment]) {
        guard selectedMeeting?.id == meetingId,
              let meeting = meetings.first(where: { $0.id == meetingId }) else { return }
        if playerManager.player == nil {
            // Meeting was selected before its recording file existed — do the
            // full load (player + segments).
            loadMeetingInPlayer(meeting)
        } else {
            playerManager.segments = segments
        }
    }

    func loadMeetings() {
        meetings = storageManager.loadMeetings()
    }

    func loadGroups() {
        groups = (try? storageManager.fetchAllGroups()) ?? []
    }

    func createGroup(name: String) {
        guard let group = try? storageManager.createGroup(name: name) else {
            tomLog("User action: create group '\(name)' — failed")
            return
        }
        groups.append(group)
        tomLog("User action: created group '\(name)' (\(group.id.uuidString.prefix(8)))")
    }

    func deleteGroup(_ group: MeetingGroup) {
        tomLog("User action: delete group '\(group.name)' (\(group.id.uuidString.prefix(8)))")
        try? storageManager.deleteGroup(id: group.id)
        groups.removeAll { $0.id == group.id }
        if selectedGroupId == group.id { selectedGroupId = nil }
        // Reload meetings since group_id was unset
        loadMeetings()
    }

    func renameGroup(id: UUID, newName: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let oldName = groups[idx].name
        groups[idx].name = newName
        try? storageManager.updateGroup(groups[idx])
        tomLog("User action: renamed group '\(oldName)' → '\(newName)' (\(id.uuidString.prefix(8)))")
    }

    func moveMeetingToGroup(meetingId: UUID, groupId: UUID?) {
        guard let idx = meetings.firstIndex(where: { $0.id == meetingId }) else { return }
        meetings[idx].groupId = groupId
        try? storageManager.updateMeeting(meetings[idx])
        if selectedMeeting?.id == meetingId {
            selectedMeeting = meetings[idx]
        }
        let target: String
        if let gid = groupId {
            target = groups.first(where: { $0.id == gid })?.name ?? "group \(gid.uuidString.prefix(8))"
        } else {
            target = "All Recordings (ungrouped)"
        }
        tomLog("User action: moved meeting \(meetingId.uuidString.prefix(8)) → \(target)")
    }

    /// RAG: embed the question, retrieve the top chunks, synthesise a cited
    /// answer through Qwen. Both models are likely cold (the meeting
    /// pipeline unloads them after every job and the idle-timeout drops
    /// them ~5 min after the last question), so the first call after a
    /// quiet stretch pays a real cold-start. The UI surfaces this through
    /// `ragStage` rather than hiding it behind a generic spinner.
    func askQuestion(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        playerManager.pause()   // pause preserves position; controls are hidden while RAG view is shown

        ragIsLoading = true
        ragStage = .searching
        ragAnswer = ""
        ragSources = []

        tomLog("User action: Ask question — \(question.prefix(80))\(question.count > 80 ? "…" : "")")

        let embedder = embeddingManager
        let ai = aiManager
        let allMeetings = meetings
        let askStarted = Date()

        // Scope retrieval to the selected sidebar group. nil selection
        // ("All Recordings") searches everything; a selected group restricts the
        // search to its meetings — an empty group yields no results.
        let scopedMeetingIds: Set<UUID>? = selectedGroupId.map { _ in
            Set(filteredMeetingsByGroup.map(\.id))
        }

        // Surface the search scope so we can see exactly what RAG is restricted to.
        if let gid = selectedGroupId {
            let groupName = groups.first(where: { $0.id == gid })?.name ?? "unknown"
            let scoped = filteredMeetingsByGroup
            tomLog("Ask: scope = group '\(groupName)' (\(gid.uuidString.prefix(8))) → \(scoped.count)/\(allMeetings.count) meetings: [\(scoped.map { "\($0.title) (\($0.id.uuidString.prefix(8)))" }.joined(separator: ", "))]")
        } else {
            tomLog("Ask: scope = All Meetings → \(allMeetings.count) meetings")
        }

        Task.detached {
            do {
                // 1. Vector search: find top 8 relevant chunks, scoped to the
                //    selected group. Includes the embedder cold-load if it was
                //    unloaded.
                tomLog("Ask: searching (Search AI may need to load)…")
                let results = try await embedder.search(query: question, limit: 8, meetingIds: scopedMeetingIds)
                tomLog("Ask: search returned \(results.count) chunks")

                // 2. Enrich chunks with meeting metadata
                let contextChunks: [(text: String, meetingTitle: String, meetingDate: String)] = results.compactMap { result in
                    guard let meeting = allMeetings.first(where: { $0.id == result.meetingId }) else { return nil }
                    let dateStr = shortDateFormatter.string(from: meeting.date)
                    return (text: result.chunkText, meetingTitle: meeting.title, meetingDate: dateStr)
                }

                // 3. Collect unique source meetings
                var seenIds = Set<UUID>()
                let sources: [(meetingTitle: String, meetingDate: String)] = results.compactMap { result in
                    guard let meeting = allMeetings.first(where: { $0.id == result.meetingId }),
                          seenIds.insert(meeting.id).inserted else { return nil }
                    return (meetingTitle: meeting.title, meetingDate: shortDateFormatter.string(from: meeting.date))
                }

                guard !contextChunks.isEmpty else {
                    await MainActor.run {
                        self.ragAnswer = String(localized: "Nothing in your recordings answers this question.")
                        self.ragIsLoading = false
                        self.ragStage = .idle
                        self.dropAIModelsAfterSearch()
                    }
                    return
                }

                // 4. Retrieval-first: surface the sources as soon as the
                //    vector search lands, so the user sees *what* was found
                //    while Qwen cold-loads and writes. The answer then
                //    streams in token by token.
                tomLog("Ask: synthesising answer (Think AI may need to load)…")
                await MainActor.run {
                    self.ragSources = sources
                    self.ragStage = .synthesizing
                }

                // Deltas arrive on the inference thread and are re-applied on
                // the main actor as monotonic snapshots. Snapshot-assign (not
                // append) keeps out-of-order Task hops harmless: a stale
                // snapshot is strictly shorter, and the count guard drops it.
                // The stage guard drops any straggler that lands after the
                // final answer/error assignment below.
                let streamBuffer = RAGStreamBuffer()
                let answer = try await ai.ragAnswer(
                    question: question,
                    contextChunks: contextChunks,
                    onDelta: { delta in
                        let snapshot = streamBuffer.append(delta)
                        Task { @MainActor in
                            guard self.ragStage == .synthesizing,
                                  snapshot.count > self.ragAnswer.count else { return }
                            self.ragAnswer = snapshot
                        }
                    }
                )

                await MainActor.run {
                    self.ragAnswer = answer
                    self.ragIsLoading = false
                    self.ragStage = .idle
                    self.dropAIModelsAfterSearch()
                }
                tomLog("Ask: complete in \(String(format: "%.1f", Date().timeIntervalSince(askStarted)))s (\(answer.count) chars, \(sources.count) sources)")
            } catch {
                tomLog("RAG error: \(error)")
                await MainActor.run {
                    self.ragAnswer = String(localized: "Error: \(error.localizedDescription)")
                    self.ragIsLoading = false
                    self.ragStage = .idle
                    self.dropAIModelsAfterSearch()
                }
            }
        }
    }

    // MARK: - AI Model Eviction

    /// Evict AI models from memory before a recording starts. The
    /// post-recording pipeline re-loads what it needs serially (each
    /// ~10–30 s cold start), so paying that cost later is cheaper than
    /// holding ~4 GB resident while the recorder is also driving the GPU for
    /// H.264 encoding. When live transcription is running, Whisper is the
    /// engine doing the live work — keep it and warm it instead.
    /// Fire-and-forget — recording start shouldn't block on model teardown.
    private func dropAIModelsForRecording(keepVoiceAI: Bool = false) {
        let transcriber = transcriptionManager
        let ai = aiManager
        let embedder = embeddingManager
        Task.detached {
            if keepVoiceAI {
                await TranscriptionEngine.selected.preload()
            } else {
                await transcriber.unload()
            }
            await ai.unload()
            await embedder.unload()
            tomLog("Recording: dropped \(keepVoiceAI ? "Think + Search AI (Voice AI stays live)" : "Voice + Think + Search AI") to free memory")
        }
    }

    /// One-time-per-binary Whisper warm-up. Loading the model after an app
    /// update triggers a CoreML/ANE recompile that takes minutes (149–170 s
    /// measured) — long enough to eat an entire short recording's live
    /// transcription window. Compiling once in the background right after
    /// launch means the load at recording time drops to seconds. The compile
    /// cache persists on disk, so the model is unloaded again immediately —
    /// no steady-state RAM cost.
    private var prewarmTask: Task<Void, Never>?

    private func prewarmVoiceAIIfNeeded() {
        let buildKey = "tom.voiceAIPrewarmedBuild"
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let engine = TranscriptionEngine.selected
        guard prewarmTask == nil,
              LiveTranscription.isEnabled,
              engine.isReady,
              UserDefaults.standard.string(forKey: buildKey) != currentBuild,
              !isRecording else { return }
        tomLog("Voice AI: prewarming \(engine.rawValue) for build \(currentBuild) (one-time CoreML compile after update)")
        prewarmTask = Task.detached(priority: .background) {
            await engine.preload()
            // Keep it resident only if a recording started while we compiled.
            if await !(AppState.shared?.isRecording ?? false) {
                await engine.service.unload()
            }
            UserDefaults.standard.set(currentBuild, forKey: buildKey)
            tomLog("Voice AI: prewarm complete")
        }
    }

    /// Builds the live-transcription session for a new recording, or nil when
    /// the feature is off / the model isn't downloaded. Discovered utterances
    /// stream straight into `liveTranscripts[meetingId]` for the preview.
    private func makeLiveSession(
        meetingId: UUID,
        sources: [String: String],
        primary: String,
        mixing: [String] = []
    ) -> StreamingTranscriptionSession? {
        guard LiveTranscription.isEnabled, TranscriptionEngine.selected.isReady else {
            tomLog("Live transcription: disabled (enabled=\(LiveTranscription.isEnabled), engine=\(TranscriptionEngine.selected.rawValue), modelReady=\(TranscriptionEngine.selected.isReady))")
            return nil
        }
        tomLog("Live transcription: session started (sources=\(sources.keys.sorted().joined(separator: "+")))")
        // Empty-string entry renders as the "warming up" preview immediately.
        liveTranscripts[meetingId] = ""
        // Bring the new meeting on screen so the live transcript is visible
        // without hunting for it; DetailContent opens its Transcript tab.
        if let meeting = meetings.first(where: { $0.id == meetingId }) {
            selectedMeeting = meeting
        }
        let session = StreamingTranscriptionSession(sources: sources, primary: primary, mixing: mixing) { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for text in update.committed {
                    let existing = self.liveTranscripts[meetingId] ?? ""
                    self.liveTranscripts[meetingId] = existing.isEmpty ? text : existing + "\n" + text
                }
                // Ignore a late tail once the live view is gone.
                if let preview = update.preview, self.liveTranscripts[meetingId] != nil {
                    self.liveVolatile[meetingId] = preview.isEmpty ? nil : preview
                }
            }
        }
        liveSession = session
        return session
    }

    /// Evict Qwen + embedder immediately after an Ask completes. The next
    /// question pays the cold-load again (~10–15 s Qwen, a few s embedder) —
    /// acceptable trade for returning to baseline RAM between questions
    /// rather than holding ~2.5 GB resident for 5 minutes "just in case."
    /// Fire-and-forget — UI shouldn't wait on teardown.
    private func dropAIModelsAfterSearch() {
        let ai = aiManager
        let embedder = embeddingManager
        Task.detached {
            await ai.unload()
            await embedder.unload()
            tomLog("Ask: dropped Think + Search AI immediately after search")
        }
    }

    var filteredMeetingsByGroup: [Meeting] {
        guard let gid = selectedGroupId else { return meetings }
        return meetings.filter { $0.groupId == gid }
    }

    func deleteMeeting(_ meeting: Meeting) {
        tomLog("User action: delete meeting \(meeting.id.uuidString.prefix(8)) '\(meeting.title)' (kind=\(meeting.kind.rawValue), duration=\(Int(meeting.duration))s)")
        // Stop player if this meeting is playing
        if selectedMeeting?.id == meeting.id {
            playerManager.stop()
            selectedMeeting = nil
        }

        // Delete recording files from disk (mp4 + sibling .m4a / .mic.wav if present)
        if !meeting.recordingPath.isEmpty {
            let fileURL = RecordingManager.recordingsDirectory
                .appendingPathComponent(meeting.recordingPath)
            let base = fileURL.deletingPathExtension()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: base.appendingPathExtension("m4a"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("mic.wav"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("mic-muxed"))
        }
        if meeting.kind == .learning {
            try? FileManager.default.removeItem(at: RecordingManager.recordingsDirectory
                .appendingPathComponent(LearningSession.folderName(for: meeting.id), isDirectory: true))
        }

        // Delete from database
        try? storageManager.deleteMeeting(id: meeting.id)

        // Remove from in-memory list
        meetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Meeting Detection

    private func evaluateMeetingDetection(in windows: [SCWindow]) {
        // Don't interrupt an active recording with a "start recording?" prompt.
        guard !isRecording else { return }
        // Toggle is opt-out; default is ON (set in init for new installs).
        let enabled = (UserDefaults.standard.object(forKey: "tom.notifyMeetingStart") as? Bool) ?? true
        guard enabled else { return }

        let detected = meetingDetector.evaluate(windows: windows)
        for meeting in detected {
            tomLog("Meeting detected: \(meeting.displayName) bundle=\(meeting.bundleID) sessionID=\(meeting.sessionID) title=\(meeting.windowTitle.debugDescription)")
            sendMeetingDetectedNotification(meeting)
        }
    }

    /// Records that the user dismissed (or otherwise rejected) a detected
    /// meeting prompt. Subsequent polls will not re-notify for this session.
    func markMeetingDismissed(sessionID: String) {
        meetingDetector.markDismissed(sessionID: sessionID)
    }

    /// Starts recording for a window identified by `CGWindowID`. Used by the
    /// notification "Start Recording" action — bypasses the window picker.
    func startRecordingByWindowID(_ windowID: CGWindowID) {
        guard canCreateMeetings else {
            tomLog("startRecordingByWindowID blocked: \(recordingBlockedReason ?? "unknown")")
            return
        }
        guard !isRecording else { return }
        if let window = availableWindows.first(where: { $0.windowID == windowID }) {
            startRecording(window: window)
            return
        }
        // Window list may be slightly stale (poll runs every 3s). Refresh once
        // and retry — gives the user a usable click even if the cache missed.
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                if let window = content.windows.first(where: { $0.windowID == windowID }) {
                    self.startRecording(window: window)
                } else {
                    tomLog("startRecordingByWindowID: window \(windowID) no longer available")
                }
            } catch {
                tomLog("startRecordingByWindowID refresh failed: \(error)")
            }
        }
    }

    private func sendMeetingDetectedNotification(_ meeting: DetectedMeeting) {
        guard Bundle.main.bundleIdentifier != nil else {
            tomLog("Skipped meeting notification: Bundle.main.bundleIdentifier is nil (run as .app bundle)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(meeting.displayName) meeting detected")
        content.body = meeting.windowTitle
        content.sound = .default
        content.categoryIdentifier = "MEETING_DETECTED"
        content.userInfo = [
            "type": "meetingDetected",
            "windowID": NSNumber(value: meeting.windowID),
            "sessionID": meeting.sessionID,
        ]

        let request = UNNotificationRequest(
            identifier: "tom-meeting-\(meeting.sessionID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                tomLog("Failed to post meeting-detected notification: \(error)")
            } else {
                tomLog("Posted meeting-detected notification: \(meeting.displayName)")
            }
        }
    }

    // MARK: - Notifications

    func sendNotification(title: String, body: String, meetingId: UUID) {
        guard !NSApp.isActive else { return } // Skip if TOM is frontmost
        guard Bundle.main.bundleIdentifier != nil else { return } // Requires app bundle
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["meetingId": meetingId.uuidString]

        let request = UNNotificationRequest(
            identifier: "tom-\(meetingId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// False while recording, while an export of this meeting runs, and for
    /// video when the recording has no video track.
    func canExportMedia(_ meeting: Meeting, kind: AudioMuxer.ExportKind) -> Bool {
        !meeting.recordingPath.isEmpty && meeting.state != .recording
            && !exportingMeetingIDs.contains(meeting.id)
            && (kind == .audio || meeting.hasVideo)
    }

    /// Asks for a destination, then writes the meeting's video (.mp4) or audio
    /// (.m4a) there in the background. Mic and system audio are both included.
    func exportMedia(_ meeting: Meeting, kind: AudioMuxer.ExportKind) {
        guard canExportMedia(meeting, kind: kind) else { return }
        let ext = kind == .video ? "mp4" : "m4a"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == .video ? .mpeg4Movie : .mpeg4Audio]
        panel.nameFieldStringValue = meeting.exportFileName(ext: ext)
        tomLog("User action: Export \(kind.rawValue) (meeting=\(meeting.id.uuidString.prefix(8)))")
        guard panel.runModal() == .OK, let destination = panel.url else {
            tomLog("Export \(kind.rawValue) cancelled")
            return
        }

        let recording = RecordingManager.recordingsDirectory.appendingPathComponent(meeting.recordingPath)
        let mic = Self.micSidecarURL(for: meeting, videoURL: recording)
        let id = meeting.id
        exportingMeetingIDs.insert(id)
        Task.detached {
            do {
                try await AudioMuxer.exportMeetingMedia(recording: recording, mic: mic, kind: kind, to: destination)
                tomLog("Export \(kind.rawValue) saved: \(destination.lastPathComponent)")
            } catch {
                tomLog("Export \(kind.rawValue) failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Export failed")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
            await MainActor.run { _ = self.exportingMeetingIDs.remove(id) }
        }
    }

    /// Asks for a folder name, then writes a Learning session's review for a
    /// coding agent there: review.md, screens/, annotations.json.
    func exportSpecFolder(_ meeting: Meeting) {
        guard meeting.kind == .learning, !exportingMeetingIDs.contains(meeting.id) else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (meeting.exportFileName(ext: "md") as NSString).deletingPathExtension + " spec"
        tomLog("User action: Export spec folder (meeting=\(meeting.id.uuidString.prefix(8)))")
        guard panel.runModal() == .OK, let folder = panel.url else {
            tomLog("Export spec folder cancelled")
            return
        }
        let storage = storageManager
        let id = meeting.id
        exportingMeetingIDs.insert(id)
        Task.detached {
            let fm = FileManager.default
            // Built next to the destination first, so a failed export never
            // costs the folder being replaced.
            let staging = folder.deletingLastPathComponent()
                .appendingPathComponent(".tom-spec-\(UUID().uuidString)", isDirectory: true)
            do {
                let annotations = try storage.fetchAnnotations(meetingId: id)
                let segments = try storage.fetchTranscriptSegments(meetingId: id)
                try LearningReview.writeSpecFolder(
                    to: staging, title: meeting.title, date: meeting.date,
                    annotations: annotations, segments: segments,
                    recordings: RecordingManager.recordingsDirectory
                )
                // The panel already confirmed "Replace"; trash rather than
                // delete so a mistakenly picked folder can be recovered.
                if fm.fileExists(atPath: folder.path) {
                    try fm.trashItem(at: folder, resultingItemURL: nil)
                }
                try fm.moveItem(at: staging, to: folder)
                tomLog("Export spec folder saved: \(folder.lastPathComponent) (\(annotations.count) annotations)")
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            } catch {
                try? fm.removeItem(at: staging)
                tomLog("Export spec folder failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Export failed")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
            await MainActor.run { _ = self.exportingMeetingIDs.remove(id) }
        }
    }

    /// Copies a Feedback session for Claude or ChatGPT (review + annotated
    /// screenshots as files) and opens a new chat there; ⌘V attaches it.
    func sendToAI(_ meeting: Meeting, target: AIHandoff.Target) {
        guard meeting.kind == .learning, !exportingMeetingIDs.contains(meeting.id) else { return }
        tomLog("User action: Send to \(target.name) (meeting=\(meeting.id.uuidString.prefix(8)))")
        let storage = storageManager
        let id = meeting.id
        exportingMeetingIDs.insert(id)
        Task.detached {
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TOM Feedback", isDirectory: true)
                    .appendingPathComponent(id.uuidString, isDirectory: true)
                let package = try AIHandoff.build(
                    title: meeting.title, date: meeting.date,
                    annotations: try storage.fetchAnnotations(meetingId: id),
                    segments: try storage.fetchTranscriptSegments(meetingId: id),
                    recordings: RecordingManager.recordingsDirectory,
                    target: target, into: folder
                )
                tomLog("Send to \(target.name): copied \(package.files.count) files (\(package.omittedImages) screenshots over the limit)")
                await MainActor.run {
                    AIHandoff.copy(package)
                    AIHandoff.open(target)
                    HandoffNotice.show(package, target: target)
                }
            } catch {
                tomLog("Send to \(target.name) failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Export failed")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
            await MainActor.run { _ = self.exportingMeetingIDs.remove(id) }
        }
    }

    /// Sets a user-chosen meeting title that the AI won't overwrite. A blank
    /// title hands the title back to the AI on the next (re)transcription.
    func renameMeeting(id: UUID, title: String) {
        tomLog("User action: rename meeting \(id.uuidString.prefix(8))")
        updateMeeting(id: id) { $0.rename(to: title) }
    }

    /// Sets a display name for a raw speaker label in a single meeting. An empty
    /// name resets the alias. Persists immediately. The alias is applied to the
    /// summary and transcript at render/copy/export time via `Meeting.aliased*`,
    /// so renames are free — no AI re-run, no DB rewrite of the stored text.
    func renameSpeaker(meetingId: UUID, raw: String, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMeeting(id: meetingId) { meeting in
            if trimmed.isEmpty {
                meeting.speakerAliases.removeValue(forKey: raw)
            } else {
                meeting.speakerAliases[raw] = trimmed
            }
        }
    }

    private func updateMeetingState(id: UUID?, state: MeetingState) {
        guard let id else { return }
        updateMeeting(id: id) { $0.state = state }
    }

    private func updateMeeting(id: UUID, transform: (inout Meeting) -> Void) {
        if let index = meetings.firstIndex(where: { $0.id == id }) {
            var meeting = meetings[index]
            transform(&meeting)
            meetings[index] = meeting
            try? storageManager.updateMeeting(meeting)

            if selectedMeeting?.id == id {
                selectedMeeting = meeting
            }
        }
    }
}

// MARK: - RAG Streaming Buffer

/// Accumulates streamed answer deltas off the main actor. `append` returns
/// the full text so far, letting the UI apply order-insensitive snapshots
/// instead of appends (a re-ordered append would duplicate or scramble
/// text; a re-ordered snapshot is just stale and gets dropped).
final class RAGStreamBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ delta: String) -> String {
        lock.withLock {
            text += delta
            return text
        }
    }
}

// MARK: - RAG Stage

/// High-level phase of an in-flight Ask. Cold-load latency is rolled into the
/// relevant phase rather than surfaced as a separate "loading models" stage,
/// so the UI just shows what TOM is actually doing.
enum RAGStage: Equatable {
    /// Nothing is happening — input is empty or the answer is on screen.
    case idle
    /// Embedding the query + scanning vectors. Includes the embedder cold
    /// load if it was unloaded (~3–5 s).
    case searching
    /// Qwen is generating the cited answer from the retrieved chunks.
    /// Includes the LLM cold load if it was unloaded (~10–15 s).
    case synthesizing
}
