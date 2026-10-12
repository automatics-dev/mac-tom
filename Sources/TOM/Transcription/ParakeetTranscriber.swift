import AVFoundation
import FluidAudio
import Foundation

// MARK: - Engine Selection

/// Which local model transcribes audio. Parakeet is the real-time engine —
/// ~110× realtime on Apple Silicon and a fraction of Whisper's memory — while
/// Whisper remains the accuracy pick and powers the optional post-meeting
/// re-transcription pass.
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case parakeet
    case whisper

    var id: String { rawValue }

    static let key = "tom.transcription.engine"

    /// Resolved engine for live + standard post-stop transcription. Defaults
    /// to Parakeet once its model is on disk (existing installs keep working
    /// on Whisper without a new download). A stored choice whose model has
    /// since vanished falls back to whichever engine is actually ready.
    static var selected: TranscriptionEngine {
        let stored = UserDefaults.standard.string(forKey: key).flatMap(TranscriptionEngine.init(rawValue:))
        switch stored {
        case .parakeet where ParakeetTranscriber.isModelReady:
            return .parakeet
        case .whisper where WhisperKitTranscriber.isModelReady:
            return .whisper
        case .parakeet, .whisper:
            return ParakeetTranscriber.isModelReady ? .parakeet : .whisper
        case nil:
            return ParakeetTranscriber.isModelReady ? .parakeet : .whisper
        }
    }

    static func set(_ engine: TranscriptionEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: key)
    }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet v3 — real-time, 25 languages"
        case .whisper: "Whisper large-v3-turbo — highest accuracy"
        }
    }

    var isReady: Bool {
        switch self {
        case .parakeet: ParakeetTranscriber.isModelReady
        case .whisper: WhisperKitTranscriber.isModelReady
        }
    }

    var service: TranscribingService {
        switch self {
        case .parakeet: ParakeetTranscriber.shared
        case .whisper: WhisperKitTranscriber.shared
        }
    }

    func preload() async {
        switch self {
        case .parakeet: await ParakeetTranscriber.shared.preload()
        case .whisper: await WhisperKitTranscriber.shared.preload()
        }
    }

    /// Live-chunk entry point used by `StreamingTranscriptionSession`.
    func transcribeSamples(_ samples: [Float]) async throws -> TranscriptionOutcome {
        switch self {
        case .parakeet: try await ParakeetTranscriber.shared.transcribeSamples(samples)
        case .whisper: try await WhisperKitTranscriber.shared.transcribeSamples(samples)
        }
    }
}

// MARK: - Whisper Re-transcription Preference

/// When on, a meeting transcribed live by Parakeet gets a second, full-file
/// Whisper large-v3-turbo pass after recording stops — the live transcript
/// is the instant draft, Whisper's output replaces it for archival quality.
/// All hallucination filters apply to the re-transcribed output exactly as
/// they do to the live pass.
enum WhisperRetranscription {
    static let key = "tom.retranscribeWithWhisper"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key) && WhisperKitTranscriber.isModelReady
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

// MARK: - ParakeetTranscriber

/// On-device transcription via FluidAudio + NVIDIA Parakeet TDT 0.6b v3
/// (CoreML, Apple Neural Engine). ~110× realtime, 25 European languages,
/// ~500 MB of int8 weights — the engine behind live transcription. Audio
/// never leaves the Mac.
///
/// Same actor pattern as `WhisperKitTranscriber`: lazy shared manager,
/// in-flight-load dedup, explicit download gate so inference never triggers
/// a silent multi-hundred-MB fetch.
actor ParakeetTranscriber: TranscribingService {

    static let shared = ParakeetTranscriber()

    static let readyKey = "tom.modelReady.parakeet"
    static var isModelReady: Bool {
        UserDefaults.standard.bool(forKey: Self.readyKey) && isModelOnDisk
    }

    /// FluidAudio manages its own cache (Application Support); ask it rather
    /// than probing paths by hand.
    static var isModelOnDisk: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    /// `nonisolated(unsafe)` for the same reason as
    /// `WhisperKitTranscriber.pipe` — only actor-isolated methods touch it.
    private nonisolated(unsafe) var manager: AsrManager?
    private nonisolated(unsafe) var loadingTask: Task<AsrManager, Error>?

    /// Downloads (or verifies) the Parakeet v3 CoreML models with progress
    /// reporting. Idempotent — FluidAudio skips files already on disk.
    func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        tomLog("Parakeet: download starting (parakeet-tdt-0.6b-v3)")
        let started = Date()
        _ = try await AsrModels.download(version: .v3) { p in
            progress(p.fractionCompleted)
        }
        UserDefaults.standard.set(true, forKey: Self.readyKey)
        tomLog("Parakeet: download complete in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    /// Warm the models ahead of need (recording start) so the first live
    /// chunk isn't stuck behind the cold load. Errors are swallowed — a
    /// failed preload just means the first chunk pays the load itself.
    func preload() async {
        guard Self.isModelReady else { return }
        _ = try? await ensureManager()
    }

    func unload() async {
        let wasLoaded = manager != nil || loadingTask != nil
        if let manager { await manager.cleanup() }
        manager = nil
        loadingTask = nil
        if wasLoaded {
            tomLog("Parakeet: unloaded from memory")
        }
    }

    // MARK: Transcription

    /// Live-streaming path: raw 16 kHz mono samples for one ~15–30 s chunk.
    /// Mirrors `WhisperKitTranscriber.transcribeSamples` — actor isolation
    /// serialises concurrent chunk requests from system + mic sources.
    func transcribeSamples(_ samples: [Float]) async throws -> TranscriptionOutcome {
        guard Self.isModelReady else { throw TranscriptionError.modelNotLoaded }
        let manager = try await ensureManager()
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return Self.outcome(from: result)
    }

    nonisolated func transcribe(
        fileURL: URL,
        onSegmentDiscovered: (@Sendable (String) -> Void)?
    ) async throws -> TranscriptionOutcome {
        try await loadAndTranscribe(fileURL: fileURL, onSegmentDiscovered: onSegmentDiscovered)
    }

    private func loadAndTranscribe(
        fileURL: URL,
        onSegmentDiscovered: (@Sendable (String) -> Void)?
    ) async throws -> TranscriptionOutcome {
        guard Self.isModelReady else { throw TranscriptionError.modelNotLoaded }
        let manager = try await ensureManager()

        tomLog("Parakeet: transcribing \(fileURL.lastPathComponent)")
        let started = Date()
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(fileURL, decoderState: &state)
        tomLog("Parakeet: transcription done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (\(result.text.count) chars)")

        let outcome = Self.outcome(from: result)
        // Parakeet decodes the whole file in one pass, so "streaming" the
        // discovered segments happens after the fact — still worth it, the
        // preview fills in the moment decode lands rather than after the
        // full pipeline (summary, embeddings) completes.
        if let onSegmentDiscovered {
            for seg in outcome.segments {
                onSegmentDiscovered(seg.text)
            }
        }
        return outcome
    }

    /// Converts one ASRResult into TOM's utterance-level segments. Token
    /// timings → word timings → per-word micro-segments → silence-gap folding
    /// (same 1.5 s folding the Whisper path uses) → hallucination filter.
    /// Parakeet v3 does not report a detected language, so `language` is nil
    /// and downstream prompts fall back to "match the transcript language".
    nonisolated static func outcome(from result: ASRResult) -> TranscriptionOutcome {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return TranscriptionOutcome(segments: [], language: nil) }

        let wordTimings = buildWordTimings(from: result.tokenTimings ?? [])
        let segments: [TranscriptSegment]
        if wordTimings.isEmpty {
            // No timing data — single segment spanning the audio. Karaoke
            // falls back to linear interpolation, same as old recordings.
            segments = [
                TranscriptSegment(
                    startTime: 0,
                    endTime: result.duration,
                    speaker: "Speaker",
                    text: text,
                    words: nil
                )
            ]
        } else {
            let wordSegments = wordTimings.map { w in
                TranscriptSegment(
                    startTime: w.startTime,
                    endTime: w.endTime,
                    speaker: "Speaker",
                    text: w.word,
                    words: [WordStamp(text: w.word, start: w.startTime, end: w.endTime)]
                )
            }
            segments = WhisperKitTranscriber.groupBySilenceGaps(wordSegments)
        }

        let filtered = segments.filter { seg in
            guard WhisperKitTranscriber.isHallucination(seg.text) else { return true }
            tomLog("Parakeet: dropped hallucinated segment (\(seg.text.count) chars): \(String(seg.text.prefix(80)))")
            return false
        }
        return TranscriptionOutcome(segments: filtered, language: nil)
    }

    private func ensureManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loadingTask {
            tomLog("Parakeet: joining in-flight load")
            return try await loadingTask.value
        }
        tomLog("Parakeet: loading model into memory…")
        let started = Date()
        let task = Task<AsrManager, Error> {
            // downloadAndLoad is a no-op download when files are already on
            // disk (guarded by isModelReady above), then loads the CoreML
            // models onto the Neural Engine.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        self.loadingTask = task
        do {
            let manager = try await task.value
            self.manager = manager
            self.loadingTask = nil
            tomLog("Parakeet: loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return manager
        } catch {
            self.loadingTask = nil
            tomLog("Parakeet: load failed — \(error.localizedDescription)")
            throw error
        }
    }
}
