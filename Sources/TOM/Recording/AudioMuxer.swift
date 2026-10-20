import AVFoundation
import Foundation

private final class Ref<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Post-recording audio processing.
///
/// Two responsibilities:
/// 1. Compress raw PCM mic captures so they fit Whisper's 25 MB upload cap.
/// 2. Mix the mic into the recording's mp4 audio track so playback (TOM's player
///    or any external player) contains the user's voice alongside system audio.
enum AudioMuxer {

    // MARK: - Whisper Upload Compression

    /// Returns a URL to an audio file that fits under Whisper's 25 MB upload cap.
    /// If the input is already small enough, returns it unchanged. Otherwise
    /// transcodes to 32 kbps mono AAC m4a (sufficient quality for Whisper) into a
    /// sibling `<name>.whisper.m4a` file.
    static func ensureFitsForWhisper(audioURL: URL) async throws -> URL {
        let cap = 24 * 1024 * 1024  // headroom for multipart overhead
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if size > 0, size <= cap {
            return audioURL
        }

        let outputURL = audioURL
            .deletingPathExtension()
            .appendingPathExtension("whisper.m4a")
        try? FileManager.default.removeItem(at: outputURL)
        try await transcodeToCompactAAC(input: audioURL, output: outputURL)
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("[TOM] ensureFitsForWhisper: \(size / 1024)KB → \(outSize / 1024)KB at \(outputURL.lastPathComponent)")
        return outputURL
    }

    // MARK: - Time-Range Slice

    /// Exports a `[startSec, endSec)` slice of an audio file as a new m4a.
    /// Used to chunk long recordings under per-call duration caps imposed by
    /// some models when needed.
    static func exportAudioSlice(source: URL, startSec: Double, endSec: Double, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioMuxerError.exportSessionInitFailed
        }
        session.outputURL = output
        session.outputFileType = .m4a
        let timescale: CMTimeScale = 600
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: timescale),
            end: CMTime(seconds: endSec, preferredTimescale: timescale)
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? AudioMuxerError.exportFailed("audio slice status \(session.status.rawValue)")
        }
    }

    // MARK: - Mix Mic into Video

    /// Mixes mic audio into the mp4's audio track so playback contains the user's
    /// voice alongside system audio. Idempotent: a sidecar `<id>.mic-muxed`
    /// marker prevents repeat work on retranscribe.
    ///
    /// `preExtractedSysAudio` lets the caller skip the redundant audio extraction
    /// when it has already pulled the m4a out of the mp4 (the transcription
    /// pipeline does, to keep a clean "Other" source separate from the muxed mp4).
    static func muxMicIntoVideo(
        videoURL: URL,
        micURL: URL,
        preExtractedSysAudio: URL? = nil
    ) async throws {
        let dir = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let markerURL = dir.appendingPathComponent("\(stem).mic-muxed")
        if FileManager.default.fileExists(atPath: markerURL.path) {
            print("[TOM] muxMicIntoVideo: marker present, skipping for \(stem)")
            return
        }

        let mixedAudioURL = dir.appendingPathComponent("\(stem).mixed.m4a")
        try? FileManager.default.removeItem(at: mixedAudioURL)

        // Recorded with system audio off (Learning sessions): the mic is the
        // only audio there is.
        let hasSystemAudio = !(try await AVURLAsset(url: videoURL).loadTracks(withMediaType: .audio).isEmpty)
        var sysAudioURL: URL?
        var cleanupSysAudio = false
        if !hasSystemAudio {
            try await exportAudioOnly(from: micURL, to: mixedAudioURL)
        } else if let pre = preExtractedSysAudio, FileManager.default.fileExists(atPath: pre.path) {
            sysAudioURL = pre
        } else {
            let extracted = dir.appendingPathComponent("\(stem).sys.m4a")
            try? FileManager.default.removeItem(at: extracted)
            try await exportAudioOnly(from: videoURL, to: extracted)
            sysAudioURL = extracted
            cleanupSysAudio = true
        }
        if let sysAudioURL {
            try mixAudioOffline(sysAudioURL: sysAudioURL, micURL: micURL, outputURL: mixedAudioURL)
        }

        let mixedVideoURL = dir.appendingPathComponent("\(stem).mixed.mp4")
        try? FileManager.default.removeItem(at: mixedVideoURL)
        try await muxVideoAndAudio(videoURL: videoURL, audioURL: mixedAudioURL, outputURL: mixedVideoURL)

        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: mixedVideoURL)

        if cleanupSysAudio, let sysAudioURL {
            try? FileManager.default.removeItem(at: sysAudioURL)
        }
        try? FileManager.default.removeItem(at: mixedAudioURL)
        FileManager.default.createFile(atPath: markerURL.path, contents: nil)
        print("[TOM] muxMicIntoVideo: mic mixed into \(videoURL.lastPathComponent)")
    }

    // MARK: - User Export

    enum ExportKind: String {
        case video, audio
    }

    /// Writes a meeting's media to `destination` for the user. Both sides of
    /// the conversation are always included: an already-muxed recording is
    /// copied (video) or has its audio extracted, otherwise the `.mic.wav`
    /// sidecar is mixed in on the fly without touching the stored recording.
    static func exportMeetingMedia(
        recording: URL,
        mic: URL?,
        kind: ExportKind,
        to destination: URL
    ) async throws {
        let stem = recording.deletingPathExtension().lastPathComponent
        let marker = recording.deletingLastPathComponent().appendingPathComponent("\(stem).mic-muxed")
        let pendingMic = FileManager.default.fileExists(atPath: marker.path) ? nil : mic
        let isM4A = recording.pathExtension.lowercased() == "m4a"

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tom-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // Exports land in `work` first so a failure never leaves a partial
        // file at the user's chosen location.
        let staged = work.appendingPathComponent("export.\(kind == .video ? "mp4" : "m4a")")

        if let pendingMic {
            let mixed = try await mixedAudio(recording: recording, mic: pendingMic, in: work)
            if kind == .video {
                try await muxVideoAndAudio(videoURL: recording, audioURL: mixed, outputURL: staged)
            } else {
                try FileManager.default.moveItem(at: mixed, to: staged)
            }
        } else if kind == .video || isM4A {
            try FileManager.default.copyItem(at: recording, to: staged)
        } else {
            try await exportAudioOnly(from: recording, to: staged)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    /// Recording audio + mic mixed into one AAC m4a inside `dir`. A recording
    /// without an audio track (system audio off) yields the mic alone.
    private static func mixedAudio(recording: URL, mic: URL, in dir: URL) async throws -> URL {
        let output = dir.appendingPathComponent("mixed.m4a")
        let hasRecordingAudio = !(try await AVURLAsset(url: recording).loadTracks(withMediaType: .audio).isEmpty)
        guard hasRecordingAudio else {
            try await exportAudioOnly(from: mic, to: output)
            return output
        }
        let sysAudio = dir.appendingPathComponent("sys.m4a")
        try await exportAudioOnly(from: recording, to: sysAudio)
        try mixAudioOffline(sysAudioURL: sysAudio, micURL: mic, outputURL: output)
        return output
    }

    // MARK: - Internals

    private static func exportAudioOnly(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioMuxerError.exportSessionInitFailed
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? AudioMuxerError.exportFailed("audio extract status \(session.status.rawValue)")
        }
    }

    private static func mixAudioOffline(sysAudioURL: URL, micURL: URL, outputURL: URL) throws {
        let sysFile = try AVAudioFile(forReading: sysAudioURL)
        let micFile = try AVAudioFile(forReading: micURL)

        let engine = AVAudioEngine()
        let sysPlayer = AVAudioPlayerNode()
        let micPlayer = AVAudioPlayerNode()
        engine.attach(sysPlayer)
        engine.attach(micPlayer)

        guard let mixingFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw AudioMuxerError.formatCreationFailed
        }
        // Connect each player in its own native PCM format; the mainMixerNode
        // resamples / upmixes (mono mic → stereo) to the engine's mix format.
        engine.connect(sysPlayer, to: engine.mainMixerNode, format: sysFile.processingFormat)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: micFile.processingFormat)

        try engine.enableManualRenderingMode(.offline, format: mixingFormat, maximumFrameCount: 4096)
        try engine.start()

        sysPlayer.scheduleFile(sysFile, at: nil)
        micPlayer.scheduleFile(micFile, at: nil)
        sysPlayer.play()
        micPlayer.play()

        let sysFramesInMix = AVAudioFramePosition(Double(sysFile.length) / sysFile.processingFormat.sampleRate * mixingFormat.sampleRate)
        let micFramesInMix = AVAudioFramePosition(Double(micFile.length) / micFile.processingFormat.sampleRate * mixingFormat.sampleRate)
        let totalFrames = max(sysFramesInMix, micFramesInMix)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let mixedFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: mixingFormat, frameCapacity: 4096) else {
            throw AudioMuxerError.bufferAllocFailed
        }

        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                try mixedFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                // No live inputs in offline mode; if we somehow stall, bail out so
                // we don't spin forever.
                return
            case .error:
                throw AudioMuxerError.renderFailed
            @unknown default:
                return
            }
        }

        sysPlayer.stop()
        micPlayer.stop()
        engine.stop()
    }

    /// Re-encodes an audio file to 32 kbps mono AAC m4a. Used when an upload
    /// would otherwise exceed Whisper's 25 MB cap; 32 kbps mono fits ~100 minutes
    /// per 24 MB and stays well within Whisper's accuracy envelope for speech.
    private static func transcodeToCompactAAC(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioMuxerError.missingTracks
        }

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        guard reader.canAdd(trackOutput) else {
            throw AudioMuxerError.exportSessionInitFailed
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw reader.error ?? AudioMuxerError.exportFailed("compact AAC reader start failed")
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioMuxerError.exportSessionInitFailed
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw writer.error ?? AudioMuxerError.exportFailed("compact AAC writer start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "ai.meettom.whisper-compress")
        let rInput = Ref(writerInput)
        let rOutput = Ref(trackOutput)
        let rWriter = Ref(writer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rInput.value.requestMediaDataWhenReady(on: queue) {
                while rInput.value.isReadyForMoreMediaData {
                    if let buffer = rOutput.value.copyNextSampleBuffer() {
                        rInput.value.append(buffer)
                    } else {
                        rInput.value.markAsFinished()
                        rWriter.value.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        if writer.status != .completed {
            throw writer.error ?? AudioMuxerError.exportFailed("compact AAC writer status \(writer.status.rawValue)")
        }
        if reader.status == .failed {
            throw reader.error ?? AudioMuxerError.exportFailed("compact AAC reader status \(reader.status.rawValue)")
        }
    }

    private static func muxVideoAndAudio(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
            throw AudioMuxerError.missingTracks
        }
        // Each track at its own length. ScreenCaptureKit sends no frames
        // while the screen is static, so the video can end well before the
        // audio; the player holds the last frame instead of the narration
        // being cut off.
        let videoDuration = try await videoTrack.load(.timeRange).duration
        let audioDuration = try await audioTrack.load(.timeRange).duration

        let composition = AVMutableComposition()
        let videoCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let audioCompTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        try videoCompTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack, at: .zero
        )
        try audioCompTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: audioTrack, at: .zero
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw AudioMuxerError.exportSessionInitFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw exporter.error ?? AudioMuxerError.exportFailed("video+audio mux status \(exporter.status.rawValue)")
        }
    }
}

// MARK: - Errors

enum AudioMuxerError: LocalizedError {
    case exportSessionInitFailed
    case exportFailed(String)
    case formatCreationFailed
    case bufferAllocFailed
    case renderFailed
    case missingTracks

    var errorDescription: String? {
        switch self {
        case .exportSessionInitFailed: "Could not create AVAssetExportSession."
        case let .exportFailed(detail): "Audio export failed: \(detail)"
        case .formatCreationFailed: "Could not create mixing AVAudioFormat."
        case .bufferAllocFailed: "Could not allocate AVAudioPCMBuffer."
        case .renderFailed: "AVAudioEngine offline render returned error status."
        case .missingTracks: "Source asset is missing required video or audio track."
        }
    }
}
