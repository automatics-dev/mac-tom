import AVFoundation
import Combine

@MainActor
final class PlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Double = 0.75 {
        didSet { player?.volume = Float(volume) }
    }
    @Published var currentSegmentIndex: Int = -1
    @Published var showVideo = true  // toggle between video+transcript vs audio-only+transcript

    /// Published so transcript views re-render the moment the pipeline
    /// finishes and AppState pushes fresh segments — without it the user had
    /// to reselect the meeting (or ⌘R) to see the transcript appear.
    @Published var segments: [TranscriptSegment] = []  // loaded from DB

    private var timeObserver: Any?
    private var durationTask: Task<Void, Never>?
    private var isSeeking = false

    func load(url: URL, segments: [TranscriptSegment], hasVideo: Bool = true) {
        stop()
        let p = AVPlayer(url: url)
        p.volume = Float(volume)
        self.player = p
        self.segments = segments
        self.showVideo = hasVideo

        // Get duration — task is cancelled in stop() if user switches meeting before it finishes
        durationTask = Task {
            if let d = try? await p.currentItem?.asset.load(.duration) {
                guard !Task.isCancelled else { return }
                duration = d.seconds.isNaN ? 0 : d.seconds
            }
        }

        // Time observer — fires every 0.1 seconds
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isSeeking else { return }
                self.currentTime = time.seconds
                self.updateCurrentSegment()
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        isSeeking = true
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSeeking = false
            }
        }
    }

    func skipForward(_ seconds: Double = 15) {
        seek(to: min(duration, currentTime + seconds))
    }

    func skipBackward(_ seconds: Double = 15) {
        seek(to: max(0, currentTime - seconds))
    }

    func stop() {
        durationTask?.cancel()
        durationTask = nil
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSegmentIndex = -1
        // Clear segments so selecting a meeting that has no recording (or is
        // still transcribing) never shows the previous meeting's transcript.
        segments = []
    }

    func toggleVideoMode() {
        showVideo.toggle()
    }

    private func updateCurrentSegment() {
        let t = currentTime
        // Prefer a segment whose range actually contains `t` — with two
        // interleaved streams (mic "Me" + system "Speaker") the timeline has
        // overlapping segments, and the old "last started before t" rule
        // could park the highlight on a segment that ended long ago. Fall
        // back to the last-started segment during inter-segment silence.
        let idx = segments.lastIndex(where: { $0.startTime <= t && t <= $0.endTime })
            ?? segments.lastIndex(where: { $0.startTime <= t })
        if let idx, currentSegmentIndex != idx {
            currentSegmentIndex = idx
        }
    }

    nonisolated func cleanup() {
        // Call from deinit or when no longer needed
        MainActor.assumeIsolated {
            if let obs = timeObserver, let p = player {
                p.removeTimeObserver(obs)
            }
        }
    }
}
