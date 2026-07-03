import AVFoundation
import Foundation
import WhisperKit

// MARK: - Retroactive Sendable

/// WhisperKit is a non-final reference type that pre-dates Swift's strict
/// concurrency checking. We confine all access to a single actor
/// (`WhisperKitTranscriber`) and never share an instance across threads
/// without going through that actor's isolation, so this conformance is safe
/// in TOM's usage. Without it, every reference to the type from inside an
/// actor emits a Swift 6 forward-warning.
extension WhisperKit: @unchecked @retroactive Sendable {}

// MARK: - Result + Backend Protocol

/// What a transcription call hands back. Beyond the timestamped segments,
/// we also surface the language Whisper auto-detected so downstream
/// prompts can explicitly tell the LLM what language to respond in —
/// "match the transcript language" instructions are unreliable on smaller
/// models like Qwen 3 4B, especially for short voice notes.
struct TranscriptionOutcome: Sendable {
    let segments: [TranscriptSegment]
    /// ISO 639-1 code reported by Whisper ("en", "ro", "fr", …). `nil`
    /// when the recording is too short to detect or no segments survived
    /// cleaning.
    let language: String?

    /// Resolves the ISO code to its English name ("ro" → "Romanian") for
    /// inclusion in LLM prompts. Falls back to the raw code, then to nil
    /// if no language was detected at all. English locale is used so the
    /// substituted value is stable regardless of the user's system
    /// language — the prompt is read by the LLM, not the user.
    var languageName: String? {
        guard let language else { return nil }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: language) ?? language
    }
}

/// Service that turns audio into time-stamped transcript segments + the
/// detected source language.
protocol TranscribingService: Sendable {
    func transcribe(fileURL: URL) async throws -> TranscriptionOutcome

    /// Free any in-memory model state held by this service. Default
    /// implementation is a no-op; backends that hold large CoreML / MLX
    /// weights override this so the pipeline can drop them between stages.
    /// Called between Whisper transcription and Qwen summarisation in
    /// `processRecording` to free ~2 GB of unified memory before the LLM
    /// prefills its KV cache for long meetings.
    func unload() async
}

extension TranscribingService {
    func unload() async {}
}

// MARK: - TranscriptionManager

/// Thin wrapper around a `TranscribingService`. Keeps the existing call-site
/// API (`transcribeFullRecording` / `transcribeDiarized`) so AppState doesn't
/// have to change; both methods route to the same local backend now that
/// diarization is removed.
final class TranscriptionManager: @unchecked Sendable {

    private let service: TranscribingService

    init(service: TranscribingService = WhisperKitTranscriber.shared) {
        self.service = service
    }

    func transcribeFullRecording(fileURL: URL) async throws -> TranscriptionOutcome {
        try await service.transcribe(fileURL: fileURL)
    }

    /// Retained for source compatibility with AppState. Local backend has no
    /// diarization, so this routes through the same single-speaker path.
    /// Speaker labels are still applied at the AppState layer ("Me" for mic,
    /// "Speaker" for system audio).
    func transcribeDiarized(fileURL: URL) async throws -> TranscriptionOutcome {
        try await service.transcribe(fileURL: fileURL)
    }

    /// Drop the cached model from memory so the next stage in the pipeline
    /// (Qwen summarisation) has room to allocate its KV cache for long
    /// transcripts. The next transcription call re-loads the model (~30 s
    /// cold start), which is acceptable because `ProcessingQueue` runs
    /// jobs serially.
    func unload() async {
        await service.unload()
    }
}

// MARK: - WhisperKitTranscriber

/// On-device transcription via WhisperKit + Whisper large-v3-turbo (CoreML).
/// Audio never leaves the Mac. Word-level segments coming out of WhisperKit
/// are folded into utterance-level transcript segments by silence gap so the
/// rendered transcript reads as turns rather than a flat list of phrases.
///
/// Model is downloaded from HuggingFace on first use (~1.5 GB) and cached in
/// the WhisperKit framework's default location for subsequent launches. Pipe
/// is created lazily and shared across the app via `.shared` so warm-up cost
/// is paid once per process.
actor WhisperKitTranscriber: TranscribingService {

    static let shared = WhisperKitTranscriber()

    /// OpenAI's canonical Whisper Turbo release (Sept 2024) — the latest in
    /// the Whisper line. ~1.5 GB CoreML weights, near-parity with `whisper-1`
    /// on transcription accuracy, ~30–50× realtime on Apple Silicon. Variant
    /// string maps to the folder `openai_whisper-large-v3-v20240930_turbo` in
    /// `argmaxinc/whisperkit-coreml`; the `openai_whisper-` prefix is added
    /// automatically by WhisperKit's resolver.
    private let modelName = "large-v3-v20240930_turbo"

    /// Silence gap (seconds) above which two consecutive word-segments are
    /// treated as separate utterances. 1.5s catches natural speech turns
    /// without splitting mid-sentence pauses.
    private let utteranceGapSeconds: TimeInterval = 1.5

    /// `nonisolated(unsafe)` because `WhisperKit` is a non-Sendable upstream
    /// class. Only actor-isolated methods (`ensurePipe`, `loadAndTranscribe`,
    /// `download`) read or mutate this property, so the actor's serial
    /// execution still gates every access — Swift just can't prove that
    /// statically when the contained type isn't Sendable.
    private nonisolated(unsafe) var pipe: WhisperKit?

    /// In-flight load shared across concurrent callers. Without this, two
    /// concurrent `ensurePipe()` calls (e.g. system + mic transcription via
    /// `async let`) both see `pipe == nil` after their `await` suspension
    /// and race to download the tokenizer to the same path, surfacing as
    /// "config.json.<hash>.incomplete couldn't be moved".
    private nonisolated(unsafe) var loadingTask: Task<WhisperKit, Error>?

    /// UserDefaults key flipped to `true` after a successful explicit
    /// download. Combined with an on-disk check so a stale flag (model was
    /// downloaded once, then the cache directory was deleted) doesn't
    /// mislead the UI into showing Ready when inference would silently
    /// trigger a multi-GB re-download.
    static let readyKey = "tom.modelReady.transcription"
    static var isModelReady: Bool {
        UserDefaults.standard.bool(forKey: Self.readyKey) && isModelOnDisk
    }

    /// Verifies the WhisperKit CoreML weights exist in HubApi's default
    /// cache. Folder name matches the variant resolved against
    /// `argmaxinc/whisperkit-coreml`.
    static var isModelOnDisk: Bool {
        let url = huggingFaceCacheRoot()
            .appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        return directoryHasContents(url)
    }

    /// Downloads the Whisper variant with progress reporting. Idempotent —
    /// re-running after a successful download just re-verifies model files
    /// against the HuggingFace snapshot and finishes quickly.
    func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        tomLog("Voice AI: download starting (variant=\(modelName))")
        let started = Date()
        _ = try await WhisperKit.download(
            variant: modelName,
            progressCallback: { p in
                progress(p.fractionCompleted)
            }
        )
        UserDefaults.standard.set(true, forKey: Self.readyKey)
        tomLog("Voice AI: download complete in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    nonisolated func transcribe(fileURL: URL) async throws -> TranscriptionOutcome {
        try await loadAndTranscribe(fileURL: fileURL)
    }

    /// Releases the cached `WhisperKit` instance so its CoreML weights can be
    /// reclaimed. Idempotent: safe to call when nothing is loaded. The next
    /// transcription pays the full cold-start cost again (~30 s) — the
    /// trade-off is intentional, freeing ~1.5–2 GB of unified memory before
    /// the LLM stage runs prefill on a 30K+ token transcript.
    func unload() {
        let wasLoaded = pipe != nil || loadingTask != nil
        pipe = nil
        loadingTask = nil
        if wasLoaded {
            tomLog("Voice AI: unloaded from memory")
        }
    }

    private func loadAndTranscribe(fileURL: URL) async throws -> TranscriptionOutcome {
        // Refuse to run inference until the model has been explicitly
        // downloaded via Settings/Onboarding. Without this guard, calling
        // `ensurePipe` on a fresh install silently triggers a ~1.5 GB HF
        // fetch that saturates the network and stalls the UI for minutes
        // with no progress feedback.
        guard Self.isModelReady else {
            throw TranscriptionError.modelNotLoaded
        }
        let pipe = try await ensurePipe()

        tomLog("Voice AI: transcribing \(fileURL.lastPathComponent)")
        let started = Date()
        // Tightened from the WhisperKit default of 2.4 so YouTube-outro
        // hallucinations ("Thank you. Thank you. Thank you. …", "Subscribe
        // to my channel.") trigger an in-decoder retry at a higher
        // temperature instead of leaking through to the transcript.
        // `logProbThreshold` left at its default — confidence-based gating
        // is more sensitive to legitimate quiet speech and we'd rather
        // catch hallucinations via compression than via probability.
        let options = DecodingOptions(compressionRatioThreshold: 2.0)
        let results = try await pipe.transcribe(audioPath: fileURL.path, decodeOptions: options)
        // WhisperKit auto-detects language per chunk. For a normal
        // mono-language meeting every chunk reports the same code, so the
        // first chunk's value is representative. For code-switching
        // recordings (rare) the dominant language across chunks would
        // need a mode/argmax — out of scope for now.
        let detectedLanguage = results.first?.language
        tomLog("Voice AI: transcription done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (\(results.flatMap(\.segments).count) raw segments, language=\(detectedLanguage ?? "unknown"))")

        // WhisperKit returns one TranscriptionResult per audio chunk it split.
        // Concatenate segments across all chunks; timestamps are already on
        // the source-file timeline so no offset is required.
        let allSegments = results.flatMap(\.segments)

        let segments = allSegments.compactMap { seg -> TranscriptSegment? in
            let text = Self.cleanWhisperText(seg.text)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                startTime: TimeInterval(seg.start),
                endTime: TimeInterval(seg.end),
                speaker: "Speaker",
                text: text
            )
        }

        let grouped = groupBySilenceGaps(segments)
        let filtered = grouped.filter { seg in
            guard Self.isRepetitiveHallucination(seg.text) else { return true }
            tomLog("Voice AI: dropped hallucinated segment (\(seg.text.count) chars): \(String(seg.text.prefix(80)))")
            return false
        }
        if filtered.count < grouped.count {
            tomLog("Voice AI: filtered out \(grouped.count - filtered.count) hallucinated segment(s)")
        }

        return TranscriptionOutcome(
            segments: filtered,
            language: detectedLanguage
        )
    }

    /// Detects Whisper's classic silence-induced hallucinations — the
    /// "Thank you. Thank you. Thank you. …" / "Subscribe to my channel.
    /// Subscribe to my channel. …" pattern that comes from the model's
    /// YouTube-heavy training set leaking out when the audio carries no
    /// real speech. Two signals, either is enough to drop the segment:
    ///
    /// 1. **Low unique-word ratio** — short phrase repeated many times
    ///    flattens vocabulary diversity (`"Thank you." × 10 → 2 unique
    ///    words in 10`). Threshold 30% catches this cleanly while leaving
    ///    a real "yes, yes, exactly, yes" back-channel intact (those run
    ///    shorter than the 40-char floor).
    /// 2. **Exact phrase repetition** — a unit of ≥8 chars that appears
    ///    ≥3 times and covers ≥70% of the segment. Catches the longer
    ///    "Subscribe to my channel." family that the word-ratio test
    ///    misses because the phrase itself has more vocabulary.
    ///
    /// Both checks gate on length ≥40 chars so legitimate short utterances
    /// ("Yeah yeah yeah") survive.
    nonisolated static func isRepetitiveHallucination(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 40 else { return false }

        // Check 1: low unique-word ratio
        let words = cleaned
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
        if words.count >= 8 {
            let uniqueWords = Set(words)
            let uniqueRatio = Double(uniqueWords.count) / Double(words.count)
            if uniqueRatio < 0.3 { return true }
        }

        // Check 2: exact phrase repetition. Iterate unit lengths from 8 up
        // to a third of the text — shorter than 8 is too low-signal,
        // longer than a third can't repeat 3 times by definition.
        let maxUnitLen = min(cleaned.count / 3, 80)
        if maxUnitLen >= 8 {
            for unitLen in 8...maxUnitLen {
                let unit = String(cleaned.prefix(unitLen))
                // `components(separatedBy:)` returns N+1 pieces for N
                // occurrences, so `count - 1` is the occurrence count.
                let occurrences = cleaned.components(separatedBy: unit).count - 1
                guard occurrences >= 3 else { continue }
                let coverage = Double(occurrences * unitLen) / Double(cleaned.count)
                if coverage >= 0.7 { return true }
            }
        }

        return false
    }

    /// Strips Whisper's control tokens from a raw segment string. WhisperKit
    /// surfaces special tokens like `<|startoftranscript|>`, `<|en|>`,
    /// `<|transcribe|>`, and per-frame timestamp markers (`<|0.00|>`,
    /// `<|8.04|>`, …) inline in the decoded text. They're meaningless to the
    /// user and break summary / RAG / clipboard export, so we collapse them
    /// out before persisting.
    nonisolated static func cleanWhisperText(_ raw: String) -> String {
        let withoutTokens = raw.replacingOccurrences(
            of: #"<\|[^|<>]*\|>"#,
            with: " ",
            options: .regularExpression
        )
        // Collapse runs of whitespace introduced by token removal.
        let collapsed = withoutTokens.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensurePipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loadingTask {
            tomLog("Voice AI: joining in-flight load")
            return try await loadingTask.value
        }
        tomLog("Voice AI: loading model into memory…")
        let started = Date()
        let modelName = self.modelName
        let task = Task<WhisperKit, Error> {
            let config = WhisperKitConfig(
                model: modelName,
                verbose: false,
                logLevel: .info,
                prewarm: false,
                load: true,
                download: true
            )
            return try await WhisperKit(config)
        }
        self.loadingTask = task
        do {
            let pipe = try await task.value
            self.pipe = pipe
            self.loadingTask = nil
            tomLog("Voice AI: loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return pipe
        } catch {
            self.loadingTask = nil
            tomLog("Voice AI: load failed — \(error.localizedDescription)")
            throw error
        }
    }

    /// Folds adjacent transcript segments into utterance-level segments. New
    /// utterance starts whenever the inter-segment gap exceeds
    /// `utteranceGapSeconds`. Segments arrive ordered by start time from
    /// WhisperKit.
    private nonisolated func groupBySilenceGaps(_ segs: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segs.isEmpty else { return [] }

        var result: [TranscriptSegment] = []
        var current = segs[0]
        var buffer = current.text

        for next in segs.dropFirst() {
            let gap = next.startTime - current.endTime
            if gap <= utteranceGapSeconds {
                buffer += " " + next.text
                current = TranscriptSegment(
                    id: current.id,
                    startTime: current.startTime,
                    endTime: next.endTime,
                    speaker: current.speaker,
                    text: buffer
                )
            } else {
                result.append(current)
                current = next
                buffer = next.text
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - Disk-cache helpers

/// HubApi's default cache root for WhisperKit and MLXEmbedders. Both use the
/// stock swift-transformers `HubApi()` initializer which defaults to
/// `~/Documents/huggingface/models/<repo-id>/`.
func huggingFaceCacheRoot() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("huggingface", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)
}

/// MLX-LLM uses its own `defaultHubApi` configured with
/// `downloadBase: FileManager.default.urls(for: .cachesDirectory, ...)` —
/// so weights end up at `~/Library/Caches/models/<repo-id>/` rather than
/// the Documents-based path WhisperKit/MLXEmbedders use. We mirror that
/// resolution exactly so `isModelOnDisk` checks the correct location.
func mlxLLMCacheRoot() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("models", isDirectory: true)
}

/// True if `url` is a directory and contains at least one regular file
/// (recursively). Used as a cheap "model is on disk" signal — doesn't
/// validate file contents, just that something was actually downloaded.
func directoryHasContents(_ url: URL) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return false
    }
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return false }

    for case let fileURL as URL in enumerator {
        if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true,
           (values.fileSize ?? 0) > 0
        {
            return true
        }
    }
    return false
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case invalidAudioBuffer
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudioBuffer:
            "Audio buffer is missing or invalid."
        case .modelNotLoaded:
            "Whisper isn't downloaded yet. Open Settings → AI Models and finish the model download first."
        case let .transcriptionFailed(reason):
            "Transcription failed: \(reason)"
        }
    }
}
