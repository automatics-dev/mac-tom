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
    private var currentRecordingKind: MeetingKind = .meeting
    private var cachedDisplay: SCDisplay?

    /// Live-transcription session for the recording in progress (nil when
    /// live transcription is off or the model isn't ready). Created at
    /// recording start, drained via `finish()` after stop.
    private var liveSession: StreamingTranscriptionSession?

    // MARK: - Meeting Library

    @Published var groups: [MeetingGroup] = []
    @Published var selectedGroupId: UUID?  // nil = "All Meetings"
    @Published var meetings: [Meeting] = []
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
    var canCreateMeetings: Bool { aiModelsReady }

    /// Human-readable reason recording is blocked, or nil when the user can
    /// start a new meeting. Used for guard logging and intended to be
    /// surfaced inline in the recording UI. The only hard blocker is the
    /// on-device models not having finished downloading yet.
    var recordingBlockedReason: String? {
        if !aiModelsReady {
            return String(localized: "AI models aren't ready yet. Open Settings → AI Models and finish the model downloads.")
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
                self.cachedDisplay = content.displays.first
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
        guard canCreateMeetings else {
            tomLog("startRecording blocked: \(recordingBlockedReason ?? "unknown")")
            return
        }
        guard !isRecording else {
            tomLog("startRecording(window:) blocked: already recording")
            return
        }
        guard let display = cachedDisplay else {
            tomLog("No display available. Refresh windows first.")
            return
        }

        let windowTitle = window.title ?? window.owningApplication?.applicationName ?? "Meeting"
        let meetingTitle = "Recording — \(windowTitle)"

        // Create meeting in DB
        do {
            let meeting = try storageManager.createMeeting(title: meetingTitle)
            currentMeetingId = meeting.id
            meetings.insert(meeting, at: 0)
        } catch {
            tomLog("Failed to create meeting: \(error)")
            return
        }

        let session = makeLiveSession(
            meetingId: currentMeetingId!,
            sources: ["system": "Speaker", "mic": "Me"],
            primary: "system"
        )
        recordingManager.streamingSession = session
        dropAIModelsForRecording(keepVoiceAI: session != nil)

        // Stop window refresh to avoid concurrent SCShareableContent calls
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil

        isRecording = true
        currentTranscript = ""
        recordingStartTime = Date()

        // Start capture off the main actor to avoid deadlock with ScreenCaptureKit
        let recorder = recordingManager
        Task.detached {
            do {
                try await recorder.startRecording(window: window, display: display)
            } catch {
                tomLog("Failed to start recording: \(error)")
                await MainActor.run { self.isRecording = false }
            }
        }
    }

    func startRecording(display: SCDisplay) {
        guard canCreateMeetings else {
            tomLog("startRecording(display:) blocked: \(recordingBlockedReason ?? "unknown")")
            return
        }
        guard !isRecording else {
            tomLog("startRecording(display:) blocked: already recording")
            return
        }
        let displayName: String
        if CGDisplayIsBuiltin(display.displayID) != 0 {
            displayName = "Built-in Display"
        } else {
            let externalIndex = availableDisplays
                .filter { CGDisplayIsBuiltin($0.displayID) == 0 }
                .firstIndex(where: { $0.displayID == display.displayID })
            if let idx = externalIndex, availableDisplays.filter({ CGDisplayIsBuiltin($0.displayID) == 0 }).count > 1 {
                displayName = "External Display \(idx + 1)"
            } else {
                displayName = "External Display"
            }
        }
        let meetingTitle = "Recording — \(displayName)"

        do {
            let meeting = try storageManager.createMeeting(title: meetingTitle)
            currentMeetingId = meeting.id
            meetings.insert(meeting, at: 0)
        } catch {
            tomLog("Failed to create meeting: \(error)")
            return
        }

        let session = makeLiveSession(
            meetingId: currentMeetingId!,
            sources: ["system": "Speaker", "mic": "Me"],
            primary: "system"
        )
        recordingManager.streamingSession = session
        dropAIModelsForRecording(keepVoiceAI: session != nil)

        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil

        isRecording = true
        currentTranscript = ""
        recordingStartTime = Date()

        let recorder = recordingManager
        Task.detached {
            do {
                try await recorder.startRecording(display: display)
            } catch {
                tomLog("Failed to start recording: \(error)")
                await MainActor.run { self.isRecording = false }
            }
        }
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
        currentMeetingId = nil
        currentRecordingKind = .meeting
        recordingStartTime = nil
        liveSession = nil

        // Restart window refresh timer
        startWindowRefreshTimer()

        let recorder = recordingManager
        let transcriber = transcriptionManager
        let ai = aiManager
        let embedder = embeddingManager
        let storage = storageManager

        // File finalisation (ScreenCaptureKit stop + writing the mp4 to disk)
        // runs immediately and is NOT inference-bound, so it doesn't share the
        // queue with retranscribes / imports. Once the file is on disk, the
        // post-recording pipeline is enqueued so it serialises with anything
        // else the user has triggered.
        Task.detached {
            let result: RecordingResult
            do {
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

            let asset = AVURLAsset(url: fileURL)
            let duration: TimeInterval = (try? await asset.load(.duration).seconds) ?? Date().timeIntervalSince(startTime)
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
                        kind: .meeting,
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
        let startTime = recordingStartTime ?? Date()
        let session = liveSession

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

        let duration = Date().timeIntervalSince(startTime)
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
            meeting.title = String(localized: "Re-transcribing…")
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
        if kind == .voiceNote || kind == .imported || liveSegments != nil {
            systemAudioURL = videoURL
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
        if kind != .voiceNote, let micURL {
            do {
                try await AudioMuxer.muxMicIntoVideo(
                    videoURL: videoURL,
                    micURL: micURL,
                    preExtractedSysAudio: extractedSysExists ? extractedM4A : nil
                )
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
                // Local WhisperKit produces a single-speaker transcript per stream.
                // Voice notes: single stream = the user → "Me".
                // Meetings + Imports: far-side audio bucketed under "Speaker"; mic
                // labelled "Me". The user can rename "Speaker" via the per-meeting
                // alias UI when only one far-side participant is talking.
                // Mic is optional — a missing or silent mic just yields a one-sided
                // transcript.
                //
                // The primary stream feeds a live preview: every utterance the
                // decoder discovers is appended to `liveTranscripts[meetingId]`
                // so the transcript views show text while the file is still being
                // processed. Only the primary stream streams — interleaving the
                // concurrent mic pass would garble the preview.
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
                async let systemOutcomeTask: TranscriptionOutcome = effectiveTranscriber.transcribeFullRecording(
                    fileURL: systemAudioURL,
                    onSegmentDiscovered: liveUpdate
                )
                async let micOutcomeTask: TranscriptionOutcome = Self.transcribeMicSafely(
                    micURL: (kind == .voiceNote) ? nil : micURL,
                    transcriber: effectiveTranscriber
                )

                let systemOutcome = try await systemOutcomeTask
                let micOutcome = await micOutcomeTask
                let systemSegments = systemOutcome.segments
                let micSegments = micOutcome.segments
                // Prefer the system-audio side's detected language — that's
                // where most meeting content lives. Fall back to the mic side
                // for voice notes (where system audio doesn't exist) or when
                // system detection failed.
                detectedLanguage = systemOutcome.language ?? micOutcome.language

                let systemLabel = (kind == .voiceNote) ? "Me" : "Speaker"
                let labeledSystem = systemSegments.map {
                    TranscriptSegment(startTime: $0.startTime, endTime: $0.endTime, speaker: systemLabel, text: $0.text, words: $0.words)
                }
                // Mic stream is always labelled "Me". The two streams (system
                // → "Speaker", mic → "Me") were transcribed independently with
                // their own per-segment timestamps, and we just interleave by
                // startTime so the rendered transcript reads in chronological
                // order. No echo / similarity heuristic — those false-positive
                // on real two-person conversations where shared vocabulary is
                // unavoidable.
                let labeledMic = micSegments.map {
                    TranscriptSegment(startTime: $0.startTime, endTime: $0.endTime, speaker: "Me", text: $0.text, words: $0.words)
                }
                segments = (labeledSystem + labeledMic).sorted { $0.startTime < $1.startTime }
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
                    if !result.title.isEmpty {
                        meeting.title = result.title
                    }
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
                self.sendNotification(title: String(localized: "Meeting Ready"), body: String(localized: "\(title) — Summary and transcript are ready"), meetingId: meetingId)
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

    /// Mic transcription is always optional — a missing or failing mic just yields
    /// a one-sided transcript instead of failing the whole meeting. Returns `[]`
    /// when `micURL` is nil or any step throws.
    private static func transcribeMicSafely(
        micURL: URL?,
        transcriber: TranscriptionManager
    ) async -> TranscriptionOutcome {
        guard let micURL else { return TranscriptionOutcome(segments: [], language: nil) }
        do {
            return try await transcriber.transcribeFullRecording(fileURL: micURL)
        } catch {
            tomLog("Mic transcription failed (continuing with system audio only): \(error)")
            return TranscriptionOutcome(segments: [], language: nil)
        }
    }

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
            target = "All Meetings (ungrouped)"
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
        // ("All Meetings") searches everything; a selected group restricts the
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
                        self.ragAnswer = String(localized: "No relevant meeting content found for this question.")
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
    private func makeLiveSession(meetingId: UUID, sources: [String: String], primary: String) -> StreamingTranscriptionSession? {
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
        let session = StreamingTranscriptionSession(sources: sources, primary: primary) { [weak self] update in
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
