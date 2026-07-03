import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct RecordingResult {
    let videoURL: URL
    let micURL: URL?
}

final class RecordingManager: NSObject, @unchecked Sendable {

    private(set) var isRecording = false

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

    // MARK: - Start Recording

    func startRecording(window: SCWindow, display: SCDisplay) async throws {
        guard !isRecording else { return }

        let filter: SCContentFilter
        if let app = window.owningApplication {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        try await startCapture(filter: filter, config: config)
    }

    func startRecording(display: SCDisplay) async throws {
        guard !isRecording else { return }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2
        try await startCapture(filter: filter, config: config)
    }

    // MARK: - Shared Capture Setup

    private func startCapture(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = true
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
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
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

        // Audio input
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        writer.add(aInput)
        audioInput = aInput

        assetWriter = writer
        sessionStarted = false
        firstTimestamp = nil

        // Use a single serial queue for both video and audio to avoid race conditions
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)

        self.stream = stream
        try await stream.startCapture()

        // Start mic capture in parallel. If it fails (no permission, no input
        // device) we still proceed with the screen recording — system audio
        // alone is better than nothing.
        startMicCapture(baseURL: url)

        isRecording = true
        print("[TOM] Recording started: \(url.lastPathComponent)")
    }

    // MARK: - Microphone Capture

    private func startMicCapture(baseURL: URL) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[TOM] Mic input format invalid (rate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)). Skipping mic capture.")
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
            print("[TOM] Failed to open mic file: \(error). Skipping mic capture.")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.micFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                print("[TOM] mic write error: \(error)")
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            print("[TOM] Mic capture started: \(micFileURL.lastPathComponent) (\(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch)")
        } catch {
            print("[TOM] Failed to start audio engine: \(error). Skipping mic capture.")
            input.removeTap(onBus: 0)
            self.micFile = nil
            self.micURL = nil
        }
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
        if let micPath = capturedMicURL?.path {
            let size = (try? FileManager.default.attributesOfItem(atPath: micPath)[.size] as? Int) ?? 0
            if size <= 44 {  // wav header is 44 bytes — anything ≤ that means no samples written
                print("[TOM] Mic file empty (\(size) bytes), discarding.")
                try? FileManager.default.removeItem(atPath: micPath)
                capturedMicURL = nil
            } else {
                print("[TOM] Mic recording saved: \(URL(fileURLWithPath: micPath).lastPathComponent) (\(size / 1024)KB)")
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
            sessionStarted = true
            print("[TOM] Writer session started at \(timestamp.seconds)s")
        }

        switch type {
        case .screen:
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            if let pixelBuffer = sampleBuffer.imageBuffer {
                let timestamp = sampleBuffer.presentationTimeStamp
                pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: timestamp)
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
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
