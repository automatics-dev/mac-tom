import AVFoundation
import Foundation

/// Mic-only voice note recorder. Captures from the default input via
/// AVAudioEngine and writes a 16 kHz mono PCM WAV — the smallest format
/// Whisper accepts at full quality, ~32 KB/s, so a 12-hour note still fits
/// under the 25 MB API cap.
final class VoiceNoteRecorder: @unchecked Sendable {

    private(set) var isRecording = false
    /// While paused the tap drops buffers, so the note continues seamlessly.
    var isPaused = false

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var outputURL: URL?

    // Live transcription: installed by AppState before start; the tap feeds
    // it 16 kHz mono samples in parallel with the WAV write.
    var streamingSession: StreamingTranscriptionSession?
    private var streamConverter: StreamingFormatConverter?

    /// Target output format: 16 kHz mono int16 PCM. Whisper-friendly.
    private let outputFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("VoiceNoteRecorder: failed to build target audio format")
        }
        return fmt
    }()

    // MARK: - Start

    func startRecording() throws -> URL {
        guard !isRecording else { throw VoiceNoteRecorderError.alreadyRecording }

        let dir = RecordingManager.recordingsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")

        let engine = AVAudioEngine()
        let inputFormat = MicInput.prepare(engine)
        let input = engine.inputNode

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceNoteRecorderError.noInputDevice
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceNoteRecorderError.cannotBuildConverter
        }

        // AVAudioFile takes a settings dict that mirrors the on-disk format.
        // The 4-arg init pins the *processing* format (the format buffers passed to
        // `write(from:)` must be in) to match our converter's output. The 2-arg init
        // defaults processing format to non-interleaved float32, which traps inside
        // CoreAudio when we feed it interleaved int16 buffers.
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputFormat.sampleRate,
            AVNumberOfChannelsKey: outputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: writeSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        self.engine = engine
        self.converter = converter
        self.file = file
        self.outputURL = url

        let target = outputFormat
        streamConverter = streamingSession != nil ? StreamingFormatConverter(from: inputFormat) : nil
        isPaused = false
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.isPaused else { return }
            self.process(buffer: buffer, target: target)
            if let session = self.streamingSession, let converter = self.streamConverter {
                let samples = converter.convert(buffer)
                if !samples.isEmpty {
                    Task { await session.append(samples, source: "mic") }
                }
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.file = nil
            self.outputURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        isRecording = true
        print("[TOM] Voice note started: \(url.lastPathComponent) (\(Int(inputFormat.sampleRate))Hz \(inputFormat.channelCount)ch → 16kHz mono)")
        return url
    }

    // MARK: - Stop

    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        streamingSession = nil   // AppState keeps its own reference for finish()
        streamConverter = nil
        let url = outputURL
        file = nil  // closes the AVAudioFile, flushing pending writes
        outputURL = nil

        if let url {
            guard MicInput.hasSamples(url) else {
                tomLog("Voice note empty, discarding.")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("[TOM] Voice note saved: \(url.lastPathComponent) (\(size / 1024)KB)")
        }
        return url
    }

    // MARK: - Conversion

    private func process(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter, let file else { return }

        // Output capacity: scale by sample-rate ratio + a small slack.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            print("[TOM] Voice note convert error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        if outBuffer.frameLength > 0 {
            do {
                try file.write(from: outBuffer)
            } catch {
                print("[TOM] Voice note write error: \(error)")
            }
        }
    }
}

enum VoiceNoteRecorderError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case cannotBuildConverter

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Voice note recorder is already running."
        case .noInputDevice: "No audio input device available."
        case .cannotBuildConverter: "Could not build audio format converter."
        }
    }
}
