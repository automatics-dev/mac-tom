import Combine
import FluidAudio
import Foundation
import MLXLLM
import MLXLMCommon
import Security

// MARK: - Backend Protocol

/// Service that runs a system+user chat completion and returns the assistant's
/// text reply. Used for summary, title, and RAG synthesis prompts.
protocol SummarizingService: Sendable {
    func chat(system: String, user: String) async throws -> String

    /// Streaming variant of `chat`: `onDelta` receives each new fragment of
    /// the reply as it is generated, and the full reply is still returned at
    /// the end. Default falls back to `chat` and emits the whole reply as a
    /// single delta, so non-streaming backends need no changes.
    func chatStream(
        system: String,
        user: String,
        onDelta: @Sendable @escaping (String) -> Void
    ) async throws -> String

    /// Free any in-memory model state. Default no-op; backends that hold
    /// large weights override this so the pipeline can drop them between
    /// stages (and the idle-timeout coordinator can drop them between
    /// searches). Re-load happens lazily on the next `chat` call.
    func unload() async
}

extension SummarizingService {
    func unload() async {}

    func chatStream(
        system: String,
        user: String,
        onDelta: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let reply = try await chat(system: system, user: user)
        onDelta(reply)
        return reply
    }
}

// MARK: - AIManager

/// Owns prompt rendering and post-processing (trim, strip quotes from titles,
/// format RAG context); delegates the actual completion call to the injected
/// service. Default backend is `RoutingSummarizer`, which dispatches each
/// chat call to either the on-device Qwen 3 4B (default) or the user's
/// OpenAI account (BYOK, when cloud brain is enabled in Settings).
final class AIManager: Sendable {

    private let service: SummarizingService

    init(service: SummarizingService = RoutingSummarizer.shared) {
        self.service = service
    }

    // MARK: - Public API

    func generateSummary(transcript: String, kind: MeetingKind, language: String? = nil) async throws -> String {
        let system = PromptLoader.render("summary-system", with: [
            "kindNoun": kind.noun,
            "language": Self.languageHint(language),
        ])
        let reply = try await service.chat(system: system, user: transcript)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateTitle(transcript: String, kind: MeetingKind, language: String? = nil) async throws -> String {
        let system = PromptLoader.render("title-system", with: [
            "kindNoun": kind.noun,
            "language": Self.languageHint(language),
        ])
        let reply = try await service.chat(system: system, user: transcript)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
    }

    /// Resolves the optional detected-language hint passed in from the
    /// transcription layer into the string the prompt template substitutes
    /// for `{{language}}`. Whisper's auto-detect can fail on very short
    /// or noisy clips — when it does, fall back to a generic instruction
    /// so the LLM still gets a sensible directive.
    private static func languageHint(_ language: String?) -> String {
        language ?? "the same language as the transcript"
    }

    /// RAG: answer a question using retrieved context chunks from meetings.
    /// Pass `onDelta` to receive the reply incrementally as it is generated
    /// (token-streamed on the local backend, single delta on cloud backends).
    func ragAnswer(
        question: String,
        contextChunks: [(text: String, meetingTitle: String, meetingDate: String)],
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let context = contextChunks.enumerated().map { idx, chunk in
            "[\(idx + 1)] From \"\(chunk.meetingTitle)\" (\(chunk.meetingDate)):\n\(chunk.text)"
        }.joined(separator: "\n\n")

        let system = PromptLoader.render("rag-system")
        let user = PromptLoader.render("rag-user", with: [
            "question": question,
            "context": context,
        ])

        if let onDelta {
            return try await service.chatStream(system: system, user: user, onDelta: onDelta)
        }
        return try await service.chat(system: system, user: user)
    }

    func processMeeting(transcript: String, kind: MeetingKind, language: String? = nil) async throws
        -> (title: String, summary: String)
    {
        // Title path always uses a bounded sample. Most meetings establish
        // their topic in the opening few minutes; running the title prompt
        // over a full 2 h transcript would pay a 30K-token prefill for an
        // output that's six words long.
        let title = try await generateTitle(
            transcript: sampleForTitle(transcript),
            kind: kind,
            language: language
        )

        // Summary path: single-pass for short meetings (faster, simpler,
        // and the model handles them well), map-reduce for long ones —
        // keeps every Qwen call under a safe prefill ceiling so the
        // machine doesn't slow to a crawl.
        let summary: String
        if transcript.count <= Self.mapReduceThreshold {
            summary = try await generateSummary(transcript: transcript, kind: kind, language: language)
        } else {
            summary = try await summarizeViaMapReduce(transcript: transcript, kind: kind, language: language)
        }
        return (title: title, summary: summary)
    }

    /// Drop the cached LLM container so its ~2.4 GB of weights can be
    /// reclaimed. Used between pipeline stages (after summary + title, before
    /// embeddings) and by the idle-timeout coordinator (~5 min after the
    /// last search). Re-load is lazy on the next `chat` call (~10–15 s
    /// cold start).
    func unload() async {
        await service.unload()
    }

    // MARK: - Map-reduce (long meetings)

    /// Character count above which `processMeeting` switches from single-pass
    /// to chunked map-reduce summarisation. ~48K chars ≈ ~12K tokens ≈ 50 min
    /// of continuous conversation. Below the threshold, single-pass is faster
    /// and quality is comparable; above, the prefill blows up unified memory
    /// and the machine slows to a crawl, so we trade latency for stability.
    private static let mapReduceThreshold = 48_000

    /// Per-chunk character budget in the map phase. ~12K chars ≈ ~3K tokens —
    /// well under any prefill memory cliff. Each chunk's prefill peaks at
    /// well under a GB of working set, so the machine stays responsive even
    /// while a long meeting is being processed.
    private static let mapChunkSize = 12_000

    /// Cap on the rolling-context string passed into each chunk extractor.
    /// Bounds total per-chunk input (chunk + context) regardless of meeting
    /// length, so the last chunk's prefill is no larger than the first's.
    private static let runningContextCap = 2_000

    /// Cap on the title-path transcript sample. Title only needs the topic,
    /// which most meetings establish in the first few minutes; bounding here
    /// keeps prefill cheap even on multi-hour recordings.
    private static let titleSampleSize = 12_000

    private func sampleForTitle(_ transcript: String) -> String {
        if transcript.count <= Self.titleSampleSize { return transcript }
        return String(transcript.prefix(Self.titleSampleSize))
    }

    /// Long-meeting summary via map-reduce:
    ///
    /// 1. **Map** — split the transcript into ~10-min chunks. For each chunk,
    ///    run the `chunk-extract-system` prompt with a rolling running-notes
    ///    context drawn from prior chunks' extracts. Output is structured
    ///    markdown (Action Items / Decisions / Topics / Specifics).
    /// 2. **Reduce** — feed the concatenated chunk extracts back through the
    ///    user-editable `summary-system` prompt to produce the final
    ///    structured summary (TL;DR / Action Items / Decisions / Discussion /
    ///    Open Questions).
    ///
    /// Both phases keep each LLM call's input ≤ ~3K tokens, so the prefill
    /// KV cache stays small and the machine doesn't swap-thrash. Total
    /// latency on a 2 h transcript: ~70–130 s end-to-end.
    private func summarizeViaMapReduce(transcript: String, kind: MeetingKind, language: String? = nil) async throws -> String {
        let chunks = chunkTranscript(transcript)
        tomLog("Map-reduce summarisation: \(chunks.count) chunks (\(transcript.count) chars)")

        // Single-chunk corner case (transcript barely above threshold) →
        // collapse to single-pass, which is faster and produces strictly
        // equivalent quality.
        if chunks.count <= 1 {
            return try await generateSummary(transcript: transcript, kind: kind, language: language)
        }

        // Map phase
        var extracts: [String] = []
        var runningContext = ""

        for (i, chunk) in chunks.enumerated() {
            tomLog("Map-reduce: extracting chunk \(i + 1)/\(chunks.count)")
            let extract = try await extractFromChunk(
                chunk,
                index: i,
                total: chunks.count,
                runningContext: runningContext,
                language: language
            )
            if !extract.isEmpty {
                extracts.append(extract)
                // Append latest extract, then trim from the head to the cap.
                // Keeping the tail favours recency, which best disambiguates
                // pronouns / references in the next chunk.
                runningContext = condenseRunning(runningContext + "\n\n" + extract)
            }
        }

        if extracts.isEmpty {
            // No segment produced anything substantial — fall back to single
            // pass on the original transcript so the model gets one last
            // shot at finding something to say.
            return try await generateSummary(transcript: transcript, kind: kind, language: language)
        }

        // Reduce phase
        tomLog("Map-reduce: running reducer over \(extracts.count) extracts")
        let combined = """
        The following are factual extracts pulled from sequential segments of a long \(kind.noun). Each segment lists action items, decisions, topics, and specifics. Produce the final structured summary in the format defined above, deduplicating repeated points and synthesising threads that span multiple segments.


        """ + extracts.enumerated().map { i, e in
            "## Segment \(i + 1) of \(extracts.count)\n\(e)"
        }.joined(separator: "\n\n")

        let system = PromptLoader.render("summary-system", with: [
            "kindNoun": kind.noun,
            "language": Self.languageHint(language),
        ])
        let reply = try await service.chat(system: system, user: combined)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a transcript into chunks of approximately `mapChunkSize`
    /// characters, preserving line boundaries. Each transcript line is
    /// `"<Speaker>: <text>"`, so chunk cuts only happen between speaker
    /// turns, never mid-utterance.
    private func chunkTranscript(_ transcript: String) -> [String] {
        let lines = transcript.components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        for line in lines {
            let projected = current.isEmpty ? line.count : current.count + 1 + line.count
            if !current.isEmpty, projected > Self.mapChunkSize {
                chunks.append(current)
                current = line
            } else {
                current = current.isEmpty ? line : current + "\n" + line
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Run the chunk-extract prompt over a single segment, optionally
    /// prefixed by short rolling notes from earlier segments.
    private func extractFromChunk(
        _ chunk: String,
        index: Int,
        total: Int,
        runningContext: String,
        language: String? = nil
    ) async throws -> String {
        let system = PromptLoader.render("chunk-extract-system", with: [
            "language": Self.languageHint(language),
        ])
        var user = ""
        if !runningContext.isEmpty {
            user += "Running notes from earlier in the meeting:\n\(runningContext)\n\n"
        }
        user += "--- Segment \(index + 1) of \(total) ---\n\(chunk)"
        let reply = try await service.chat(system: system, user: user)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cap rolling context at `runningContextCap` chars, keeping the tail.
    private func condenseRunning(_ text: String) -> String {
        if text.count <= Self.runningContextCap { return text }
        return String(text.suffix(Self.runningContextCap))
    }
}

// MARK: - MLXSummarizer

/// On-device summarisation via MLX + Qwen 3 4B Instruct (July 2025 "2507"
/// release, 4-bit quantised). Model is downloaded from HuggingFace on first
/// use (~2.4 GB) and cached in the MLX framework's default location.
/// Container is loaded once per process via `.shared` so the ~10–15 s
/// cold-start cost is paid only on the first call.
///
/// Trade-off vs the older Qwen 2.5 14B 4-bit option: 5–7× faster inference,
/// ~6 GB less RAM and disk, much better battery, in exchange for some
/// quality on long meetings, multi-stakeholder action-item attribution, and
/// multilingual / domain-dense content. Qwen 3's architecture+training jump
/// closes most of the parameter-count gap; effective quality lands roughly
/// at the Qwen 2.5 8–9B level.
actor MLXSummarizer: SummarizingService {

    static let shared = MLXSummarizer()

    /// HuggingFace model ID. Apache 2.0 — no attribution requirements beyond
    /// the standard NOTICE in Acknowledgements.
    static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// `nonisolated(unsafe)` for the same reason as
    /// `WhisperKitTranscriber.pipe` — only actor-isolated methods access it.
    private nonisolated(unsafe) var container: ModelContainer?
    /// In-flight load shared across concurrent callers. See the matching
    /// comment on `WhisperKitTranscriber.loadingTask` for the race rationale.
    private nonisolated(unsafe) var loadingTask: Task<ModelContainer, Error>?

    static let readyKey = "tom.modelReady.summary"
    static var isModelReady: Bool {
        UserDefaults.standard.bool(forKey: Self.readyKey) && isModelOnDisk
    }

    /// Verifies the Qwen 3 4B 4-bit weights exist in MLX-LLM's cache. NOTE:
    /// MLX-LLM uses `~/Library/Caches/models/...` rather than the
    /// `~/Documents/huggingface/models/...` path WhisperKit and
    /// MLXEmbedders use; that's why this calls `mlxLLMCacheRoot()` not
    /// `huggingFaceCacheRoot()`.
    static var isModelOnDisk: Bool {
        let url = mlxLLMCacheRoot()
            .appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit", isDirectory: true)
        return directoryHasContents(url)
    }

    /// Downloads (or verifies) the LLM weights with progress reporting.
    /// Normally caches the loaded container so the next `chat(...)` call
    /// is instant — *except* when cloud brain is the active backend, in
    /// which case we drop the ~2.4 GB from RAM immediately. The user
    /// downloaded Qwen as an offline fallback, not for current inference;
    /// next-time-cloud-toggles-off pays a ~10–15 s cold reload from disk.
    func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        tomLog("Think AI: download starting (\(Self.modelID))")
        let started = Date()
        let configuration = ModelConfiguration(id: Self.modelID)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { p in
                progress(p.fractionCompleted)
            }
        )
        UserDefaults.standard.set(true, forKey: Self.readyKey)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        if CloudBrainPreferences.isCloudActiveSnapshot() {
            tomLog("Think AI: download complete in \(elapsed)s — dropped from memory (cloud brain is active)")
            // Intentionally don't assign `self.container`. The downloader's
            // `loadContainer` had to materialise the weights to verify them,
            // but holding the reference would pin 2.4 GB of unused weights.
            _ = container
        } else {
            self.container = container
            tomLog("Think AI: download + load complete in \(elapsed)s")
        }
    }

    nonisolated func chat(system: String, user: String) async throws -> String {
        try await runChat(system: system, user: user)
    }

    nonisolated func chatStream(
        system: String,
        user: String,
        onDelta: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await runChat(system: system, user: user, onDelta: onDelta)
    }

    private func runChat(
        system: String,
        user: String,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Refuse to run inference until Qwen has been explicitly downloaded
        // via Settings/Onboarding. Without this guard, a fresh install
        // silently triggers a ~9 GB HF fetch from the inference path —
        // saturating bandwidth and stalling the UI with no progress UI.
        guard Self.isModelReady else {
            throw AIError.modelNotLoaded
        }
        let container = try await ensureContainer()

        tomLog("Think AI: chat starting (system=\(system.count) chars, user=\(user.count) chars)")
        let started = Date()

        let output = try await container.perform { (context: ModelContext) -> String in
            let messages: [Chat.Message] = [
                .system(system),
                .user(user),
            ]
            let userInput = UserInput(chat: messages)
            let lmInput = try await context.processor.prepare(input: userInput)

            let parameters = GenerateParameters(
                maxTokens: 1024,
                temperature: 0.3,
                topP: 0.9
            )

            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )

            var output = ""
            for await event in stream {
                if case .chunk(let text) = event {
                    output += text
                    onDelta?(text)
                }
            }
            return output
        }

        tomLog("Think AI: chat done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (output=\(output.count) chars)")
        return output
    }

    private func ensureContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loadingTask {
            tomLog("Think AI: joining in-flight load")
            return try await loadingTask.value
        }
        tomLog("Think AI: loading model into memory…")
        let started = Date()
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(id: Self.modelID)
            return try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            )
        }
        self.loadingTask = task
        do {
            let container = try await task.value
            self.container = container
            self.loadingTask = nil
            tomLog("Think AI: loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return container
        } catch {
            self.loadingTask = nil
            tomLog("Think AI: load failed — \(error.localizedDescription)")
            throw error
        }
    }

    /// Releases the cached `ModelContainer` so its weights can be reclaimed.
    /// Idempotent. The next `chat` call re-loads the container from the
    /// on-disk cache (~10–15 s cold start). Trade-off is intentional —
    /// freeing 2.4 GB of LLM weights between meetings + during search-idle
    /// stretches keeps TOM's resident set close to baseline when not
    /// actively answering questions.
    func unload() {
        let wasLoaded = container != nil || loadingTask != nil
        container = nil
        loadingTask = nil
        if wasLoaded {
            tomLog("Think AI: unloaded from memory")
        }
    }
}

// MARK: - ModelDownloadManager

/// Coordinates the on-device model lifecycle (download progress, cached
/// readiness, re-download) for the three local services. Lives on the main
/// actor so SwiftUI can `@ObservedObject` / `@StateObject` it directly.
///
/// State is `@Published` per model so the Onboarding "Set up on-device AI"
/// step and the Settings → AI section can both bind to the same source of
/// truth.
@MainActor
final class ModelDownloadManager: ObservableObject {

    static let shared = ModelDownloadManager()

    enum Status: Equatable {
        case unknown
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var fraction: Double? {
            if case .downloading(let f) = self { return f }
            if case .ready = self { return 1.0 }
            return nil
        }
    }

    struct ModelInfo {
        let title: String
        let subtitle: String
        let icon: String
    }

    static let transcriptionInfo = ModelInfo(
        title: "Whisper large-v3-turbo",
        subtitle: "Speech → text · ~1.5 GB",
        icon: "waveform"
    )
    static let parakeetInfo = ModelInfo(
        title: "Parakeet TDT v3",
        subtitle: "Real-time speech → text · ~500 MB · 25 languages",
        icon: "bolt.badge.waveform"
    )
    static let summaryInfo = ModelInfo(
        title: "Qwen 3 4B Instruct 2507 (4-bit)",
        subtitle: "Summaries & titles · ~2.4 GB",
        icon: "brain"
    )
    static let embeddingInfo = ModelInfo(
        title: "multilingual-e5-small",
        subtitle: "Cross-meeting search · ~120 MB · 100+ languages",
        icon: "magnifyingglass"
    )

    /// Approximate download size in bytes per model. Used to weight the
    /// aggregate progress so each model contributes proportionally to its
    /// payload — without this the bar would jump as soon as the small embedder
    /// finishes (~3% of total bytes) instead of moving steadily as the big
    /// LLM weights stream in (~60% of total).
    private static let bytesTranscription: Int64 = 1_500_000_000
    private static let bytesSummary: Int64 = 2_400_000_000
    private static let bytesEmbedding: Int64 = 120_000_000
    static let bytesTotal: Int64 = bytesTranscription + bytesSummary + bytesEmbedding

    @Published private(set) var transcriptionStatus: Status = .unknown
    @Published private(set) var parakeetStatus: Status = .unknown
    @Published private(set) var summaryStatus: Status = .unknown
    @Published private(set) var embeddingStatus: Status = .unknown

    /// Wall-clock time of the most recent transition into "any download in
    /// flight." Used as the basis for the ETA estimate. Reset to `nil` when
    /// the queue drains (`anyDownloading` goes false) so the next batch's
    /// ETA starts fresh.
    @Published private(set) var downloadingSince: Date?

    private init() {
        refreshFromDisk()
    }

    /// Whisper + embeddings always required on-device. The summary slot is
    /// satisfied by *either* the Qwen weights being on disk *or* the user
    /// having enabled cloud brain (BYOK with an OpenAI API key) — in that
    /// mode the summary/title/RAG calls route to OpenAI and the local LLM
    /// download is optional.
    var allReady: Bool {
        let summaryReady = summaryStatus.isReady || CloudBrainPreferences.shared.isActive
        return transcriptionStatus.isReady && summaryReady && embeddingStatus.isReady
    }

    var anyDownloading: Bool {
        transcriptionStatus.isDownloading || summaryStatus.isDownloading || embeddingStatus.isDownloading
    }

    // MARK: - Aggregate progress

    /// Bytes-weighted aggregate progress 0…1 across all three models. Each
    /// model contributes proportional to its size, so the bar moves smoothly
    /// even though per-file `fractionCompleted` from the underlying snapshot
    /// downloader is non-monotonic and jumps when individual files finish.
    var aggregateFraction: Double {
        let t = Self.fraction(for: transcriptionStatus)
        let s = Self.fraction(for: summaryStatus)
        let e = Self.fraction(for: embeddingStatus)
        let totalD = Double(Self.bytesTotal)
        return (t * Double(Self.bytesTranscription)
                + s * Double(Self.bytesSummary)
                + e * Double(Self.bytesEmbedding)) / totalD
    }

    /// Bytes downloaded so far across the three models, derived from the
    /// aggregate fraction. Exposed for "1.9 GB of 4.0 GB" UI copy.
    var aggregateBytesDownloaded: Int64 {
        Int64(aggregateFraction * Double(Self.bytesTotal))
    }

    /// Title of the model currently being downloaded — the one with the
    /// lowest in-flight fraction wins, so users see the model that's
    /// actively making progress instead of a model whose snapshot already
    /// resolved to "downloading: 1.0" but is waiting on its sibling.
    /// Returns `nil` when nothing is in flight.
    var currentlyDownloadingTitle: String? {
        let candidates: [(ModelInfo, Status)] = [
            (Self.transcriptionInfo, transcriptionStatus),
            (Self.summaryInfo, summaryStatus),
            (Self.embeddingInfo, embeddingStatus),
        ]
        let active = candidates.compactMap { info, status -> (ModelInfo, Double)? in
            if case .downloading(let f) = status { return (info, f) }
            return nil
        }
        return active.min(by: { $0.1 < $1.1 })?.0.title
    }

    /// Estimated seconds remaining for the in-flight download batch. Naïve
    /// estimate — extrapolates from elapsed-time × remaining-fraction × current-rate.
    /// Returns `nil` when no download is active or when there isn't enough
    /// progress yet to compute a stable rate (first few seconds are jittery).
    var aggregateEtaSeconds: TimeInterval? {
        guard let started = downloadingSince else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let progress = aggregateFraction
        // Avoid wild estimates in the first ~3 s before the rate stabilises.
        guard elapsed >= 3, progress > 0.005, progress < 0.999 else { return nil }
        let rate = progress / elapsed                  // fraction per second
        let remaining = max(0, 1.0 - progress)
        let eta = remaining / max(rate, 0.0001)
        // Clamp so a very-slow rate doesn't surface absurd 99-hour ETAs that
        // the user can't act on.
        return min(eta, 60 * 60 * 6)
    }

    private static func fraction(for status: Status) -> Double {
        switch status {
        case .ready: return 1.0
        case .downloading(let f): return max(0, min(1, f))
        case .notDownloaded, .unknown, .failed: return 0
        }
    }

    /// Reads the per-model `tom.modelReady.*` flags AND verifies the actual
    /// model directory exists on disk with content. Self-heals stale flags
    /// (download was completed once, then the cache directory was deleted)
    /// by clearing them when the disk check fails so the UI doesn't show
    /// "Ready" when inference would in fact silently re-download.
    func refreshFromDisk() {
        transcriptionStatus = Self.resolveStatus(
            flagKey: WhisperKitTranscriber.readyKey,
            onDisk: WhisperKitTranscriber.isModelOnDisk,
            currentStatus: transcriptionStatus
        )
        summaryStatus = Self.resolveStatus(
            flagKey: MLXSummarizer.readyKey,
            onDisk: MLXSummarizer.isModelOnDisk,
            currentStatus: summaryStatus
        )
        embeddingStatus = Self.resolveStatus(
            flagKey: MLXEmbedder.readyKey,
            onDisk: MLXEmbedder.isModelOnDisk,
            currentStatus: embeddingStatus
        )
        parakeetStatus = Self.resolveStatus(
            flagKey: ParakeetTranscriber.readyKey,
            onDisk: ParakeetTranscriber.isModelOnDisk,
            currentStatus: parakeetStatus
        )
    }

    private static func resolveStatus(
        flagKey: String,
        onDisk: Bool,
        currentStatus: Status
    ) -> Status {
        // Don't clobber an in-flight download with a NotDownloaded badge
        // just because the disk hasn't materialised the final file yet.
        if currentStatus.isDownloading { return currentStatus }

        let flag = UserDefaults.standard.bool(forKey: flagKey)
        switch (flag, onDisk) {
        case (true, true):
            return .ready
        case (true, false):
            // Flag set but files not visible. Two very different causes:
            // the cache was actually deleted (→ self-heal, force re-download)
            // or the process simply can't read the storage location right now
            // (TCC denial on ~/Documents — e.g. a differently-signed build,
            // or the user revoked Files & Folders access). Wiping the flag in
            // the second case bricks recording with no explanation AND
            // persists the damage for correctly-permissioned launches, so
            // only self-heal when the storage root is demonstrably readable.
            if modelStorageReadable {
                UserDefaults.standard.set(false, forKey: flagKey)
                return .notDownloaded
            }
            tomLog("Model check: storage not readable (permissions?) — keeping '\(flagKey)' ready flag")
            return .ready
        case (false, true):
            // Files exist but flag never set (e.g. earlier crash mid-write
            // of the flag). Trust the disk and adopt the model.
            UserDefaults.standard.set(true, forKey: flagKey)
            return .ready
        case (false, false):
            return .notDownloaded
        }
    }

    /// True when the model cache roots can actually be enumerated. A TCC
    /// denial on ~/Documents makes every model look "gone" while the files
    /// are perfectly intact — this probe distinguishes unreadable from
    /// deleted. ~/Documents always exists, so a failed listing means
    /// denied access, not absence.
    private static var modelStorageReadable: Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) != nil
    }

    /// Triggers downloads for any model not already marked ready. The three
    /// downloads run concurrently — HuggingFace tolerates parallel snapshot
    /// calls and the cumulative ~4 GB completes faster than serial fetches
    /// on most home connections.
    func downloadAll() async {
        await withTaskGroup(of: Void.self) { group in
            if !transcriptionStatus.isReady {
                group.addTask { await self.downloadTranscription() }
            }
            if !summaryStatus.isReady {
                group.addTask { await self.downloadSummary() }
            }
            if !embeddingStatus.isReady {
                group.addTask { await self.downloadEmbedding() }
            }
        }
    }

    /// Parakeet is an optional engine — not part of `downloadAll` /
    /// `allReady` (those gate onboarding on the required trio). Downloaded
    /// on demand from the Settings row or the engine picker.
    func downloadParakeet() async {
        guard !parakeetStatus.isDownloading else { return }
        markDownloadStartIfNeeded()
        parakeetStatus = .downloading(0)
        do {
            try await ParakeetTranscriber.shared.download { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.parakeetStatus = .downloading(fraction)
                }
            }
            parakeetStatus = .ready
        } catch {
            parakeetStatus = .failed(error.localizedDescription)
        }
        clearDownloadStartIfIdle()
    }

    func downloadTranscription() async {
        guard !transcriptionStatus.isDownloading else { return }
        markDownloadStartIfNeeded()
        transcriptionStatus = .downloading(0)
        do {
            try await WhisperKitTranscriber.shared.download { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.transcriptionStatus = .downloading(fraction)
                }
            }
            transcriptionStatus = .ready
        } catch {
            transcriptionStatus = .failed(error.localizedDescription)
        }
        clearDownloadStartIfIdle()
    }

    func downloadSummary() async {
        guard !summaryStatus.isDownloading else { return }
        markDownloadStartIfNeeded()
        summaryStatus = .downloading(0)
        do {
            try await MLXSummarizer.shared.download { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.summaryStatus = .downloading(fraction)
                }
            }
            summaryStatus = .ready
        } catch {
            summaryStatus = .failed(error.localizedDescription)
        }
        clearDownloadStartIfIdle()
    }

    func downloadEmbedding() async {
        guard !embeddingStatus.isDownloading else { return }
        markDownloadStartIfNeeded()
        embeddingStatus = .downloading(0)
        do {
            try await MLXEmbedder.shared.download { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.embeddingStatus = .downloading(fraction)
                }
            }
            embeddingStatus = .ready
        } catch {
            embeddingStatus = .failed(error.localizedDescription)
        }
        clearDownloadStartIfIdle()
    }

    /// Stamp `downloadingSince` the first time any model transitions into
    /// flight after an idle stretch. Subsequent concurrent downloads in the
    /// same batch share the same start time, so the ETA estimate uses the
    /// total elapsed time of the batch rather than restarting per model.
    private func markDownloadStartIfNeeded() {
        if downloadingSince == nil { downloadingSince = Date() }
    }

    /// Drop `downloadingSince` once all three models settle into a non-flight
    /// state. Called from each download method's tail; the last one to finish
    /// performs the cleanup.
    private func clearDownloadStartIfIdle() {
        if !anyDownloading { downloadingSince = nil }
    }

    // MARK: - Re-download (wipe + fetch)

    /// Deletes the cached weights for every model AND clears the readiness
    /// flags, then re-fetches all three. Without the on-disk delete, just
    /// clearing the flag is a no-op: `refreshFromDisk` immediately re-asserts
    /// `.ready` via the "files exist on disk → trust the disk" branch in
    /// `resolveStatus`. Used by the "Re-download all" button in Settings and
    /// Onboarding when the user wants a fresh fetch (e.g. after a broken
    /// snapshot or a model upgrade).
    func wipeAndRedownloadAll() async {
        wipeAllOnDisk()
        await downloadAll()
    }

    /// Wipe + redownload just the Whisper weights. Used by the per-model
    /// Re-download button on the Voice AI row.
    func wipeAndRedownloadTranscription() async {
        wipeTranscriptionOnDisk()
        await downloadTranscription()
    }

    /// Wipe + redownload the Parakeet models. FluidAudio owns the cache
    /// layout, so wiping is just deleting its model directory; `download`
    /// (force-less) then re-fetches the missing files.
    func wipeAndRedownloadParakeet() async {
        await ParakeetTranscriber.shared.unload()
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: .v3))
        UserDefaults.standard.set(false, forKey: ParakeetTranscriber.readyKey)
        parakeetStatus = .notDownloaded
        await downloadParakeet()
    }

    /// Wipe + redownload just the local LLM (Qwen). Used by the per-model
    /// Re-download button on the Think AI row, only relevant in the Local
    /// backend.
    func wipeAndRedownloadSummary() async {
        wipeSummaryOnDisk()
        await downloadSummary()
    }

    /// Wipe + redownload just the embedder. Used by the per-model Re-download
    /// button on the Search AI row.
    func wipeAndRedownloadEmbedding() async {
        wipeEmbeddingOnDisk()
        await downloadEmbedding()
    }

    private func wipeTranscriptionOnDisk() {
        let url = huggingFaceCacheRoot()
            .appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        removeIfExists(url)
        UserDefaults.standard.removeObject(forKey: WhisperKitTranscriber.readyKey)
        transcriptionStatus = .notDownloaded
    }

    private func wipeSummaryOnDisk() {
        let url = mlxLLMCacheRoot()
            .appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit", isDirectory: true)
        removeIfExists(url)
        UserDefaults.standard.removeObject(forKey: MLXSummarizer.readyKey)
        summaryStatus = .notDownloaded
    }

    private func wipeEmbeddingOnDisk() {
        let url = huggingFaceCacheRoot()
            .appendingPathComponent("intfloat/multilingual-e5-small", isDirectory: true)
        removeIfExists(url)
        UserDefaults.standard.removeObject(forKey: MLXEmbedder.readyKey)
        embeddingStatus = .notDownloaded
    }

    private func removeIfExists(_ url: URL) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
                tomLog("Re-download: wiped \(url.lastPathComponent)")
            }
        } catch {
            tomLog("Re-download: failed to wipe \(url.path): \(error)")
        }
    }

    /// Best-effort wipe of every model's on-disk weights and the corresponding
    /// readiness flag. Each delete is independent; failures are logged and do
    /// not abort the others. Errors here are non-fatal — the next `downloadAll`
    /// will surface any real download failure via the per-model `.failed`
    /// status.
    private func wipeAllOnDisk() {
        let fm = FileManager.default

        let whisperDir = huggingFaceCacheRoot()
            .appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        let summaryDir = mlxLLMCacheRoot()
            .appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit", isDirectory: true)
        let embedderDir = huggingFaceCacheRoot()
            .appendingPathComponent("intfloat/multilingual-e5-small", isDirectory: true)

        for url in [whisperDir, summaryDir, embedderDir] {
            do {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                    tomLog("Re-download: wiped \(url.lastPathComponent)")
                }
            } catch {
                tomLog("Re-download: failed to wipe \(url.path): \(error)")
            }
        }

        UserDefaults.standard.removeObject(forKey: WhisperKitTranscriber.readyKey)
        UserDefaults.standard.removeObject(forKey: MLXSummarizer.readyKey)
        UserDefaults.standard.removeObject(forKey: MLXEmbedder.readyKey)

        // Force-set statuses to .notDownloaded so the UI immediately shows the
        // download starting state. `refreshFromDisk` would also work, but
        // setting directly avoids any race against an in-flight `resolveStatus`
        // self-heal.
        transcriptionStatus = .notDownloaded
        summaryStatus = .notDownloaded
        embeddingStatus = .notDownloaded
    }
}

// MARK: - Cloud Brain (BYOK)

/// Generic Keychain wrapper. `service` is the per-provider namespace
/// ("ai.meettom.openai" / "ai.meettom.anthropic"); `account` is always
/// "apiKey" so reads/writes/deletes target a single item per provider.
private enum KeychainItem {
    static let account = "apiKey"

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    static func write(service: String, key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The three possible "brain" backends. Only one is active at a time;
/// the user picks via the Settings → AI Models → Cloud Brain section.
/// Whisper transcription and search embeddings are unaffected — those
/// always run locally regardless of this choice.
enum CloudBrainBackend: String, CaseIterable, Identifiable, Sendable {
    case local
    case openai
    case anthropic

    var id: String { rawValue }

    /// Backends offered for selection in Settings → Think AI. OpenAI and
    /// Anthropic remain fully implemented (routing, keychain, key editors,
    /// validation) but are intentionally not offered for selection in the UI.
    /// Re-enable a cloud backend by adding its case back to this list.
    static var userSelectableCases: [CloudBrainBackend] { [.local] }

    /// Short label used in the Settings picker and routing log lines.
    var displayName: String {
        switch self {
        case .local:     "Local (Qwen 3 4B)"
        case .openai:    "OpenAI (\(OpenAISummarizer.model))"
        case .anthropic: "Anthropic (\(AnthropicSummarizer.model))"
        }
    }

    fileprivate var keychainService: String? {
        switch self {
        case .local:     nil
        case .openai:    "ai.meettom.openai"
        case .anthropic: "ai.meettom.anthropic"
        }
    }
}

/// Holds the user's choice of "brain" backend (local Qwen vs OpenAI vs
/// Anthropic) and the API keys for each cloud provider. Voice-to-text
/// (Whisper) and search embeddings (multilingual-e5) always remain
/// local — they are not affected by this preference.
///
/// `isActive` is the gate read by `RoutingSummarizer` on every chat
/// call: it returns true only when the selected backend is a cloud
/// provider *and* that provider's key is in the Keychain. Picking a
/// cloud backend without a key keeps inference local so users never hit
/// a "missing key" error from an unfinished setup.
@MainActor
final class CloudBrainPreferences: ObservableObject {
    static let shared = CloudBrainPreferences()

    /// `nonisolated` so `activeBackendSnapshot()` (which runs off the
    /// main actor from the inference pipeline) can read this key
    /// without bouncing through the main actor. Safe because it's an
    /// immutable string literal — no isolation guarantees to violate.
    fileprivate nonisolated static let backendKey = "tom.cloudBrain.backend"

    @Published private(set) var backend: CloudBrainBackend
    @Published private(set) var hasOpenAIKey: Bool
    @Published private(set) var hasAnthropicKey: Bool
    @Published private(set) var isActive: Bool

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.backendKey)
        let backend = raw.flatMap(CloudBrainBackend.init(rawValue:)) ?? .local
        let hasOpenAI = KeychainItem.read(service: CloudBrainBackend.openai.keychainService!) != nil
        let hasAnthropic = KeychainItem.read(service: CloudBrainBackend.anthropic.keychainService!) != nil
        let active = Self.computeActive(backend: backend, hasOpenAI: hasOpenAI, hasAnthropic: hasAnthropic)
        self.backend = backend
        self.hasOpenAIKey = hasOpenAI
        self.hasAnthropicKey = hasAnthropic
        self.isActive = active
        tomLog("Cloud Brain init: selected=\(backend.rawValue) (\(backend.displayName)) active=\(active) keys=[openai:\(hasOpenAI) anthropic:\(hasAnthropic)]")
    }

    func setBackend(_ b: CloudBrainBackend) {
        let wasActive = isActive
        let previous = backend
        backend = b
        UserDefaults.standard.set(b.rawValue, forKey: Self.backendKey)
        isActive = Self.computeActive(backend: b, hasOpenAI: hasOpenAIKey, hasAnthropic: hasAnthropicKey)
        tomLog("User action: Cloud Brain backend changed \(previous.rawValue) → \(b.rawValue) (\(b.displayName)) — active=\(isActive)")
        if isActive && !wasActive { dropLocalLLM() }
    }

    func setOpenAIKey(_ key: String) {
        let wasActive = isActive
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = CloudBrainBackend.openai.keychainService!
        if trimmed.isEmpty {
            KeychainItem.delete(service: service)
            hasOpenAIKey = false
            tomLog("User action: OpenAI API key cleared via Save with empty field")
        } else {
            KeychainItem.write(service: service, key: trimmed)
            hasOpenAIKey = true
            tomLog("User action: OpenAI API key saved to Keychain (model=\(OpenAISummarizer.model))")
        }
        isActive = Self.computeActive(backend: backend, hasOpenAI: hasOpenAIKey, hasAnthropic: hasAnthropicKey)
        if isActive && !wasActive { dropLocalLLM() }
    }

    func clearOpenAIKey() {
        KeychainItem.delete(service: CloudBrainBackend.openai.keychainService!)
        hasOpenAIKey = false
        isActive = Self.computeActive(backend: backend, hasOpenAI: hasOpenAIKey, hasAnthropic: hasAnthropicKey)
        tomLog("User action: OpenAI API key cleared from Keychain — active=\(isActive)")
    }

    func setAnthropicKey(_ key: String) {
        let wasActive = isActive
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = CloudBrainBackend.anthropic.keychainService!
        if trimmed.isEmpty {
            KeychainItem.delete(service: service)
            hasAnthropicKey = false
            tomLog("User action: Anthropic API key cleared via Save with empty field")
        } else {
            KeychainItem.write(service: service, key: trimmed)
            hasAnthropicKey = true
            tomLog("User action: Anthropic API key saved to Keychain (model=\(AnthropicSummarizer.model))")
        }
        isActive = Self.computeActive(backend: backend, hasOpenAI: hasOpenAIKey, hasAnthropic: hasAnthropicKey)
        if isActive && !wasActive { dropLocalLLM() }
    }

    func clearAnthropicKey() {
        KeychainItem.delete(service: CloudBrainBackend.anthropic.keychainService!)
        hasAnthropicKey = false
        isActive = Self.computeActive(backend: backend, hasOpenAI: hasOpenAIKey, hasAnthropic: hasAnthropicKey)
        tomLog("User action: Anthropic API key cleared from Keychain — active=\(isActive)")
    }

    private static func computeActive(backend: CloudBrainBackend, hasOpenAI: Bool, hasAnthropic: Bool) -> Bool {
        switch backend {
        case .local:     return false
        case .openai:    return hasOpenAI
        case .anthropic: return hasAnthropic
        }
    }

    /// Fires when cloud-brain transitions to active. If Qwen happens to be
    /// loaded in RAM from earlier in this session (e.g. the user picked a
    /// cloud backend *after* generating a summary locally), reclaim those
    /// ~2.4 GB right away rather than waiting for the idle-unload timer.
    private func dropLocalLLM() {
        tomLog("Cloud brain activated (\(backend.rawValue)) — unloading local Qwen from memory")
        Task { await MLXSummarizer.shared.unload() }
    }

    // MARK: - Nonisolated snapshots for off-main routing

    /// Resolves which backend should actually serve the next chat call.
    /// Returns `.local` if the user picked a cloud backend but hasn't
    /// added that provider's key yet — saves users from a "missing key"
    /// error on a partially-configured install.
    nonisolated static func activeBackendSnapshot() -> CloudBrainBackend {
        let raw = UserDefaults.standard.string(forKey: backendKey) ?? CloudBrainBackend.local.rawValue
        let backend = CloudBrainBackend(rawValue: raw) ?? .local
        guard let service = backend.keychainService else { return .local }
        return KeychainItem.read(service: service) != nil ? backend : .local
    }

    /// Convenience for callers that only need to know "are we on cloud or
    /// not" without caring which provider.
    nonisolated static func isCloudActiveSnapshot() -> Bool {
        activeBackendSnapshot() != .local
    }

    nonisolated static func readOpenAIKeySnapshot() -> String? {
        KeychainItem.read(service: CloudBrainBackend.openai.keychainService!)
    }

    nonisolated static func readAnthropicKeySnapshot() -> String? {
        KeychainItem.read(service: CloudBrainBackend.anthropic.keychainService!)
    }
}

// MARK: - OpenAISummarizer

/// Cloud "brain" backend powered by the user's own OpenAI API key. Used
/// only when `CloudBrainPreferences.activeBackendSnapshot()` returns
/// `.openai`. Always hits the most capable model — per product intent,
/// if you're routing to the cloud you want the best; otherwise stay on
/// Qwen.
///
/// Wire format is the standard Chat Completions endpoint, which maps 1:1
/// to the existing `SummarizingService.chat(system:user:)` contract — no
/// prompt rewriting needed. Whisper transcripts and search embeddings are
/// not sent through this path; only the rendered system+user prompt for
/// summary/title/RAG calls.
actor OpenAISummarizer: SummarizingService {
    static let shared = OpenAISummarizer()

    static let model = "gpt-5"
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Long-meeting prompts can take a while server-side. 2 min per
        // request is generous; the resource timeout caps the worst case.
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    nonisolated func chat(system: String, user: String) async throws -> String {
        guard let key = CloudBrainPreferences.readOpenAIKeySnapshot() else {
            throw AIError.cloudKeyMissing("OpenAI")
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        tomLog("Cloud brain (OpenAI): POST \(Self.model) (system=\(system.count) chars, user=\(user.count) chars)")
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            tomLog("Cloud brain (OpenAI): network error — \(error.localizedDescription)")
            throw AIError.cloudNetworkError("OpenAI", error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.cloudNetworkError("OpenAI", "Invalid response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            tomLog("Cloud brain (OpenAI): HTTP \(http.statusCode) — \(message)")
            throw AIError.cloudHTTPError("OpenAI", http.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw AIError.cloudHTTPError("OpenAI", http.statusCode, "Could not parse response")
        }

        tomLog("Cloud brain (OpenAI): chat done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (output=\(content.count) chars)")
        return content
    }

    func unload() async {}

    /// Cheap auth probe: `GET /v1/models` returns 200 on a valid key, 401
    /// on a wrong/expired/revoked one. Doesn't bill (no completion
    /// tokens), so it's safe to call on every Save. Strict on network
    /// failures by design — we'd rather refuse to save than persist a
    /// key we can't confirm works.
    static func validate(key: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIError.cloudNetworkError("OpenAI", error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.cloudNetworkError("OpenAI", "Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AIError.cloudKeyInvalid("OpenAI", extractErrorMessage(from: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw AIError.cloudHTTPError("OpenAI", http.statusCode, msg)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message
    }
}

// MARK: - AnthropicSummarizer

/// Cloud "brain" backend powered by the user's own Anthropic API key.
/// Pinned to Claude Opus 4.7 — Anthropic's most capable model — for the
/// same reason as the OpenAI backend: if you're paying for cloud, get
/// the strongest available; otherwise stay on the on-device Qwen.
///
/// Anthropic's `/v1/messages` API takes `system` as a top-level field
/// (not a message role like OpenAI), so the request body shape differs
/// from `OpenAISummarizer` but the result of mapping `(system, user) →
/// text` is identical from the caller's perspective. Auth header is
/// `x-api-key` plus the `anthropic-version` header required by the API.
actor AnthropicSummarizer: SummarizingService {
    static let shared = AnthropicSummarizer()

    static let model = "claude-opus-4-7"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// API revision the Messages endpoint pins to. Bumping this string
    /// without re-testing risks behaviour drift; keep in sync with
    /// Anthropic's "anthropic-version" header docs.
    private static let apiVersion = "2023-06-01"
    /// Cap response length. 4096 covers full summaries comfortably (our
    /// `summary-system` output rarely exceeds ~2K tokens); higher caps
    /// just risk runaway generations.
    private static let maxTokens = 4096

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    nonisolated func chat(system: String, user: String) async throws -> String {
        guard let key = CloudBrainPreferences.readAnthropicKeySnapshot() else {
            throw AIError.cloudKeyMissing("Anthropic")
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": Self.maxTokens,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        tomLog("Cloud brain (Anthropic): POST \(Self.model) (system=\(system.count) chars, user=\(user.count) chars)")
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            tomLog("Cloud brain (Anthropic): network error — \(error.localizedDescription)")
            throw AIError.cloudNetworkError("Anthropic", error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.cloudNetworkError("Anthropic", "Invalid response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            tomLog("Cloud brain (Anthropic): HTTP \(http.statusCode) — \(message)")
            throw AIError.cloudHTTPError("Anthropic", http.statusCode, message)
        }

        // Anthropic returns `content: [ { type: "text", text: "..." }, ... ]`.
        // For pure-text completions there's a single text block; concatenating
        // them is the safe general handling.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]]
        else {
            throw AIError.cloudHTTPError("Anthropic", http.statusCode, "Could not parse response")
        }
        let text = blocks
            .compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            .joined()

        guard !text.isEmpty else {
            throw AIError.cloudHTTPError("Anthropic", http.statusCode, "Empty response body")
        }

        tomLog("Cloud brain (Anthropic): chat done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (output=\(text.count) chars)")
        return text
    }

    func unload() async {}

    /// Cheap auth probe: `GET /v1/models` returns 200 on a valid key, 401
    /// on a wrong/expired/revoked one. Doesn't bill (no message tokens),
    /// so it's safe to call on every Save. Strict on network failures by
    /// design — we'd rather refuse to save than persist a key we can't
    /// confirm works.
    static func validate(key: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIError.cloudNetworkError("Anthropic", error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.cloudNetworkError("Anthropic", "Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AIError.cloudKeyInvalid("Anthropic", extractErrorMessage(from: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw AIError.cloudHTTPError("Anthropic", http.statusCode, msg)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message
    }
}

// MARK: - RoutingSummarizer

/// Dispatches each chat call to the on-device Qwen, OpenAI, or Anthropic
/// backend based on the user's `CloudBrainPreferences` selection.
/// Re-evaluated *per call* so changing the picker in Settings takes
/// effect on the next inference without restarting the app or
/// rebuilding `AIManager`.
final class RoutingSummarizer: SummarizingService {
    static let shared = RoutingSummarizer()

    private let local: MLXSummarizer
    private let openai: OpenAISummarizer
    private let anthropic: AnthropicSummarizer

    init(
        local: MLXSummarizer = .shared,
        openai: OpenAISummarizer = .shared,
        anthropic: AnthropicSummarizer = .shared
    ) {
        self.local = local
        self.openai = openai
        self.anthropic = anthropic
    }

    func chat(system: String, user: String) async throws -> String {
        switch CloudBrainPreferences.activeBackendSnapshot() {
        case .openai:
            tomLog("Routing: CLOUD (OpenAI \(OpenAISummarizer.model))")
            return try await openai.chat(system: system, user: user)
        case .anthropic:
            tomLog("Routing: CLOUD (Anthropic \(AnthropicSummarizer.model))")
            return try await anthropic.chat(system: system, user: user)
        case .local:
            tomLog("Routing: LOCAL (Qwen 3 4B)")
            return try await local.chat(system: system, user: user)
        }
    }

    /// Must forward explicitly — the protocol's default `chatStream` would
    /// call `self.chat` and lose the local backend's token streaming.
    func chatStream(
        system: String,
        user: String,
        onDelta: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        switch CloudBrainPreferences.activeBackendSnapshot() {
        case .openai:
            tomLog("Routing: CLOUD (OpenAI \(OpenAISummarizer.model))")
            return try await openai.chatStream(system: system, user: user, onDelta: onDelta)
        case .anthropic:
            tomLog("Routing: CLOUD (Anthropic \(AnthropicSummarizer.model))")
            return try await anthropic.chatStream(system: system, user: user, onDelta: onDelta)
        case .local:
            tomLog("Routing: LOCAL (Qwen 3 4B)")
            return try await local.chatStream(system: system, user: user, onDelta: onDelta)
        }
    }

    func unload() async {
        // Local owns the heavy weights; cloud backends are no-ops.
        // Forwarding all three means callers don't need to know which
        // backend was active when they decide to free memory.
        await local.unload()
        await openai.unload()
        await anthropic.unload()
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)
    case cloudKeyMissing(String)
    case cloudKeyInvalid(String, String?)
    case cloudNetworkError(String, String)
    case cloudHTTPError(String, Int, String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return String(localized: "Qwen 3 4B isn't downloaded yet. Open Settings → AI Models and finish the model download first.")
        case let .generationFailed(reason):
            return String(localized: "AI generation failed: \(reason)")
        case let .cloudKeyMissing(provider):
            return String(localized: "Cloud brain is set to \(provider) but no \(provider) API key is in Keychain. Open Settings → AI Models to add one, or switch to the local model.")
        case let .cloudKeyInvalid(provider, detail):
            if let detail, !detail.isEmpty {
                return String(localized: "\(provider) rejected this API key: \(detail). Check the key is still active in your account dashboard.")
            }
            return String(localized: "\(provider) rejected this API key. Check it's still active in your account dashboard.")
        case let .cloudNetworkError(provider, message):
            return String(localized: "Could not reach \(provider) to verify the key: \(message). Check your connection and try again.")
        case let .cloudHTTPError(provider, code, message):
            return String(localized: "\(provider) returned \(code): \(message)")
        }
    }
}
