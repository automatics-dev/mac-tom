import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct RecordingResult {
    let videoURL: URL
    let micURL: URL?
}

/// What a screen/window recording captures besides video.
struct CaptureOptions: Equatable {
    var systemAudio = true
    var microphone = true
}

final class RecordingManager: NSObject, @unchecked Sendable {

    private(set) var isRecording = false
    /// When capture actually began; t = 0 of the recording's timeline.
    private(set) var startedAt: Date?
    /// Display being recorded (display recordings only), for filter updates.
    private var recordedDisplay: SCDisplay?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?

    private let writerQueue = DispatchQueue(label: "ai.meettom.writer")
    private var sessionStarted = false
    private var firstTimestamp: CMTime?

    // Microphone capture (parallel to SCK system audio, written to a separate .wav)
    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var micURL: URL?

    // Live transcription: AppState installs a session before starting the
    // recording; both audio taps feed it 16 kHz mono samples. nil = classic
    // transcribe-after-stop. Converters are created lazily on the first
    // buffer of each source (formats aren't known until capture starts).
    var streamingSession: StreamingTranscriptionSession?
    private var systemStreamConverter: StreamingFormatConverter?
    private var micStreamConverter: StreamingFormatConverter?

    // Pause / mute. `isPaused` and the offset are only touched on
    // writerQueue (SCK callbacks); the mic tap reads the flags directly —
    // a one-buffer race at the toggle is harmless.
    private var isPaused = false
    private var micMuted = false
    /// Total paused stretch subtracted from every timestamp after a resume.
    private var pauseOffset = CMTime.zero
    private var resumePending = false
    private var lastAdjustedPTS = CMTime.zero

    func setPaused(_ paused: Bool) {
        writerQueue.sync {
            if isPaused && !paused { resumePending = true }
            isPaused = paused
        }
    }

    func setMicMuted(_ muted: Bool) { micMuted = muted }

    // MARK: - Start Recording

    func startRecording(window: SCWindow, options: CaptureOptions = CaptureOptions()) async throws {
        guard !isRecording else { return }

        // Lock capture to the selected window: it keeps recording that window
        // when it's moved, covered, or the user switches to another window or
        // Space. A display filter including the owning app would record
        // whichever of that app's windows happens to be on screen.
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // The encoder needs even dimensions; a 1x display can yield odd ones.
        config.width = Int(filter.contentRect.width * scale) & ~1
        config.height = Int(filter.contentRect.height * scale) & ~1
        config.capturesAudio = options.systemAudio
        try await startCapture(filter: filter, config: config, microphone: options.microphone)
    }

    /// Without system audio the mp4 has no audio track until the mic is
    /// muxed in after stop.
    func startRecording(display: SCDisplay, options: CaptureOptions = CaptureOptions()) async throws {
        guard !isRecording else { return }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2
        config.capturesAudio = options.systemAudio
        recordedDisplay = display
        try await startCapture(filter: filter, config: config, microphone: options.microphone)
    }

    /// Hides the given windows (e.g. TOM's own floating controls) from an
    /// in-progress display recording.
    func excludeFromRecording(_ windows: [SCWindow]) async {
        guard let stream, let recordedDisplay else { return }
        do {
            try await stream.updateContentFilter(SCContentFilter(display: recordedDisplay, excludingWindows: windows))
        } catch {
            tomLog("Recording: failed to exclude windows (non-fatal): \(error)")
        }
    }

    // MARK: - Shared Capture Setup

    /// HEVC at native resolution. Same quality as the encoder's default
    /// H.264 at about three quarters of the size for screen content.
    static func videoSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    private func startCapture(filter: SCContentFilter, config: SCStreamConfiguration, microphone: Bool) async throws {
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        config.sampleRate = 48_000
        config.showsCursor = true

        let recordingID = UUID().uuidString
        let dir = Self.recordingsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(recordingID).mp4")
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video input
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: config.width, height: config.height))
        vInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        writer.add(vInput)
        videoInput = vInput
        pixelBufferAdaptor = adaptor

        // Audio input (system audio; skipped when the caller turned it off —
        // an input that never receives samples would fail finishWriting).
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        if config.capturesAudio {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)
            audioInput = aInput
        } else {
            audioInput = nil
        }

        assetWriter = writer
        sessionStarted = false
        firstTimestamp = nil
        isPaused = false
        micMuted = false
        pauseOffset = .zero
        resumePending = false
        lastAdjustedPTS = .zero

        // Use a single serial queue for both video and audio to avoid race conditions
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        if config.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        }

        self.stream = stream
        try await stream.startCapture()
        startedAt = Date()

        // Start mic capture in parallel. If it fails (no permission, no input
        // device) we still proceed with the screen recording — system audio
        // alone is better than nothing.
        if microphone { startMicCapture(baseURL: url) }

        isRecording = true
        print("[TOM] Recording started: \(url.lastPathComponent)")
    }

    // MARK: - Microphone Capture

    private func startMicCapture(baseURL: URL) {
        let engine = AVAudioEngine()
        let inputFormat = MicInput.prepare(engine)
        let input = engine.inputNode

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            tomLog("Mic input format invalid (rate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)). Skipping mic capture.")
            return
        }

        let micFileURL = baseURL.deletingPathExtension().appendingPathExtension("mic.wav")
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let file = try AVAudioFile(forWriting: micFileURL, settings: outputSettings)
            self.micFile = file
            self.micURL = micFileURL
        } catch {
            tomLog("Failed to open mic file: \(error). Skipping mic capture.")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.micFile, !self.isPaused else { return }
            if self.micMuted { MicInput.silence(buffer) }
            do {
                try file.write(from: buffer)
            } catch {
                tomLog("mic write error: \(error)")
            }
            self.feedStreamingSession(buffer: buffer, source: "mic")
        }

        do {
            try engine.start()
            self.audioEngine = engine
            tomLog("Mic capture started: \(micFileURL.lastPathComponent) (\(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch, permission=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
        } catch {
            tomLog("Failed to start audio engine: \(error). Skipping mic capture.")
            input.removeTap(onBus: 0)
            self.micFile = nil
            self.micURL = nil
            try? FileManager.default.removeItem(at: micFileURL)
        }
    }

    // MARK: - Live Transcription Feed

    /// Converts a tap buffer to 16 kHz mono and ships it to the streaming
    /// session. Called from the tap's own serial queue (mic) or writerQueue
    /// (system audio) — per-source converters are only ever touched from one
    /// queue each.
    private func feedStreamingSession(buffer: AVAudioPCMBuffer, source: String) {
        guard let session = streamingSession else { return }
        let converter: StreamingFormatConverter?
        switch source {
        case "mic":
            if micStreamConverter == nil {
                micStreamConverter = StreamingFormatConverter(from: buffer.format)
            }
            converter = micStreamConverter
        default:
            if systemStreamConverter == nil {
                systemStreamConverter = StreamingFormatConverter(from: buffer.format)
            }
            converter = systemStreamConverter
        }
        guard let converter else { return }
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }
        Task { await session.append(samples, source: source) }
    }

    private func stopMicCapture() -> URL? {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        let url = micURL
        micFile = nil  // closes the AVAudioFile, flushing pending writes
        micURL = nil
        return url
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> RecordingResult {
        guard isRecording else {
            throw RecordingError.notRecording
        }

        // Stop capture — tolerate errors (stream may have already stopped)
        if let stream = self.stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("[TOM] stream.stopCapture error (non-fatal): \(error)")
            }
        }
        self.stream = nil
        isRecording = false
        startedAt = nil
        recordedDisplay = nil

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        if let writer = assetWriter, writer.status == .writing {
            await writer.finishWriting()
            if writer.status == .failed, let error = writer.error {
                print("[TOM] AVAssetWriter failed: \(error)")
            }
        }

        // Stop mic capture and validate output
        var capturedMicURL = stopMicCapture()
        if let mic = capturedMicURL {
            if MicInput.hasSamples(mic) {
                let size = (try? FileManager.default.attributesOfItem(atPath: mic.path)[.size] as? Int) ?? 0
                tomLog("Mic recording saved: \(mic.lastPathComponent) (\(size / 1024)KB)")
            } else {
                tomLog("Mic file has no audio, discarding.")
                try? FileManager.default.removeItem(at: mic)
                capturedMicURL = nil
            }
        }

        guard let url = outputURL else {
            throw RecordingError.noOutputFile
        }

        // Return the file if it exists on disk, even if writer had issues
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingError.noOutputFile
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("[TOM] Recording saved: \(url.lastPathComponent) (\(fileSize / 1024)KB)")

        // Detach live-transcription plumbing; AppState still holds the
        // session and calls finish() on it after this returns.
        streamingSession = nil
        systemStreamConverter = nil
        micStreamConverter = nil

        return RecordingResult(videoURL: url, micURL: capturedMicURL)
    }

    // MARK: - Helpers

    static var recordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tom/data/recordings", isDirectory: true)
    }
}

// MARK: - SCStreamDelegate

extension RecordingManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[TOM] Stream stopped with error: \(error)")
        isRecording = false
    }
}

// MARK: - SCStreamOutput

extension RecordingManager: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // All callbacks on writerQueue (serial) — no race conditions
        guard sampleBuffer.isValid else { return }
        guard let writer = assetWriter, writer.status != .failed else { return }

        // Start session on first valid sample
        if !sessionStarted {
            let timestamp = sampleBuffer.presentationTimeStamp
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            firstTimestamp = timestamp
            lastAdjustedPTS = timestamp
            sessionStarted = true
            print("[TOM] Writer session started at \(timestamp.seconds)s")
        }

        if isPaused { return }
        // First sample after a resume: fold the paused stretch into the
        // offset so the file continues after a 0.1 s gap. The gap keeps both
        // tracks monotonic when the other track's first post-resume buffer
        // is stamped a little earlier than this one.
        let pts = sampleBuffer.presentationTimeStamp
        if resumePending {
            resumePending = false
            pauseOffset = CMTimeSubtract(CMTimeSubtract(pts, lastAdjustedPTS), CMTime(value: 1, timescale: 10))
        }
        let adjusted = CMTimeSubtract(pts, pauseOffset)
        if CMTimeCompare(adjusted, lastAdjustedPTS) > 0 { lastAdjustedPTS = adjusted }

        switch type {
        case .screen:
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            if let pixelBuffer = sampleBuffer.imageBuffer {
                pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: adjusted)
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData,
               let retimed = pauseOffset == .zero ? sampleBuffer : sampleBuffer.shifted(by: pauseOffset) {
                audioInput.append(retimed)
            }
            if streamingSession != nil, let pcm = sampleBuffer.toPCMBuffer() {
                feedStreamingSession(buffer: pcm, source: "system")
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}

private extension CMSampleBuffer {
    /// Copy with every timestamp moved earlier by `offset` (pause gaps).
    func shifted(by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: self, sampleTimingEntryCount: count,
            sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        return copy
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case notRecording
    case writerNotInitialised
    case noOutputFile

    var errorDescription: String? {
        switch self {
        case .notRecording: "No active recording to stop."
        case .writerNotInitialised: "Asset writer was not initialised."
        case .noOutputFile: "Recording output file path is missing."
        }
    }
}

extension Notification.Name {
    static let recordingDidFail = Notification.Name("recordingDidFail")
}
