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

    var segments: [TranscriptSegment] = []  // loaded from DB

    private var timeObserver: Any?
    private var durationTask: Task<Void, Never>?
    private var isSeeking = false

    func load(url: URL, segments: [TranscriptSegment]) {
        stop()
        let p = AVPlayer(url: url)
        p.volume = Float(volume)
        self.player = p
        self.segments = segments

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
    }

    func toggleVideoMode() {
        showVideo.toggle()
    }

    private func updateCurrentSegment() {
        let t = currentTime
        // Find the segment that contains the current time
        if let idx = segments.lastIndex(where: { $0.startTime <= t }) {
            if currentSegmentIndex != idx {
                currentSegmentIndex = idx
            }
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
