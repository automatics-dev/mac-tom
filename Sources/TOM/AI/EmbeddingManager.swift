import Accelerate
import Foundation
import MLX
import MLXEmbedders
import Tokenizers

// MARK: - Backend Protocol

/// Service that turns text chunks into embedding vectors for semantic search.
protocol EmbeddingService: Sendable {
    var dimension: Int { get }
    var identifier: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]

    /// Free any in-memory model state. Default no-op; backends that hold
    /// MLX containers override this so the pipeline can drop them after the
    /// embedding step (and the idle-timeout coordinator can drop them
    /// after a stretch of no searches). Re-load happens lazily on the
    /// next `embed` call.
    func unload() async
}

extension EmbeddingService {
    func unload() async {}
}

// MARK: - EmbeddingManager

/// Owns transcript chunking and SQLite persistence; delegates the actual
/// vector generation to an injected `EmbeddingService`. Default backend is
/// on-device `nomic-embed-text-v1.5` via MLX (768-dim).
final class EmbeddingManager {

    private let storageManager: StorageManager
    private let service: EmbeddingService

    // Chunking constants (approximate: 1 token ~ 4 chars)
    private let chunkSize = 2000   // ~500 tokens in chars
    private let overlapSize = 200  // ~50 tokens in chars

    init(storageManager: StorageManager, service: EmbeddingService = MLXEmbedder.shared) {
        self.storageManager = storageManager
        self.service = service
    }

    // MARK: - Public API

    /// Chunks the transcript, generates embeddings via the active service,
    /// and stores in SQLite. Replaces any prior embeddings for this meeting
    /// first so retranscribes don't stack stale chunks alongside fresh ones.
    func embedAndStore(transcript: String, meetingId: UUID) async throws {
        let chunks = chunkTranscript(transcript)
        guard !chunks.isEmpty else { return }

        let texts = chunks.map(\.text)
        let allEmbeddings = try await service.embed(texts)

        try storageManager.deleteEmbeddings(meetingId: meetingId)
        for (index, chunk) in chunks.enumerated() {
            guard index < allEmbeddings.count else { break }
            try storageManager.saveEmbedding(
                meetingId: meetingId,
                chunkText: chunk.text,
                chunkIndex: index,
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                embedding: allEmbeddings[index]
            )
        }
    }

    /// Embeds the query and returns the most similar chunks using SIMD cosine
    /// distance. Mismatched-dimension rows in the DB (e.g. left over from a
    /// previous OpenAI 1536-dim install) are filtered out by `searchSimilar`
    /// since the cosine distance helper short-circuits on length mismatch.
    /// Semantic search over stored chunks. Pass `meetingIds` to scope the
    /// search to a subset of meetings (e.g. the selected sidebar group); nil
    /// searches every meeting.
    func search(query: String, limit: Int = 5, meetingIds: Set<UUID>? = nil) async throws -> [(chunkText: String, meetingId: UUID, distance: Float)] {
        let results = try await service.embed([query])
        guard let queryEmbedding = results.first else {
            throw EmbeddingError.emptyResponse
        }
        return try storageManager.searchSimilar(queryEmbedding: queryEmbedding, limit: limit, meetingIds: meetingIds)
    }

    /// Drop the cached embedder container so its weights can be reclaimed.
    /// Used after the embedding step in the meeting pipeline and by the
    /// idle-timeout coordinator after the user stops asking questions.
    func unload() async {
        await service.unload()
    }

    // MARK: - Chunking

    private struct Chunk {
        let text: String
        let startTime: Double?
        let endTime: Double?
    }

    private func chunkTranscript(_ transcript: String) -> [Chunk] {
        let sentences = splitIntoSentences(transcript)
        guard !sentences.isEmpty else { return [] }

        var chunks: [Chunk] = []
        var currentChars: [String] = []
        var currentLen = 0

        for sentence in sentences {
            let sentenceLen = sentence.count

            if currentLen + sentenceLen > chunkSize && !currentChars.isEmpty {
                let chunkText = currentChars.joined(separator: " ")
                chunks.append(Chunk(text: chunkText, startTime: nil, endTime: nil))

                var overlapLen = currentLen
                while overlapLen > overlapSize && currentChars.count > 1 {
                    overlapLen -= currentChars.removeFirst().count + 1
                }
                currentLen = currentChars.reduce(0) { $0 + $1.count + 1 } - (currentChars.isEmpty ? 0 : 1)
            }

            currentChars.append(sentence)
            currentLen += sentenceLen + (currentChars.count > 1 ? 1 : 0)
        }

        if !currentChars.isEmpty {
            let chunkText = currentChars.joined(separator: " ")
            chunks.append(Chunk(text: chunkText, startTime: nil, endTime: nil))
        }

        return chunks
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        if sentences.isEmpty {
            sentences = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return sentences
    }
}

// MARK: - MLXEmbedder

/// On-device sentence embeddings via MLX + intfloat/multilingual-e5-small
/// (MIT, 384-dim, ~120 MB). Multilingual MiniLM backbone trained on 100+
/// languages — meaningful for TOM's audience since meetings aren't always
/// English. Model is downloaded from HuggingFace on first use; container is
/// loaded once per process via `.shared`.
actor MLXEmbedder: EmbeddingService {

    static let shared = MLXEmbedder()

    nonisolated let dimension = 384
    nonisolated let identifier = "mlx:multilingual-e5-small"

    /// `nonisolated(unsafe)` for the same reason as
    /// `WhisperKitTranscriber.pipe` — only actor-isolated methods access it.
    private nonisolated(unsafe) var container: MLXEmbedders.ModelContainer?
    /// In-flight load shared across concurrent callers. See the matching
    /// comment on `WhisperKitTranscriber.loadingTask` for the race rationale.
    private nonisolated(unsafe) var loadingTask: Task<MLXEmbedders.ModelContainer, Error>?

    static let readyKey = "tom.modelReady.embedding"
    static var isModelReady: Bool {
        UserDefaults.standard.bool(forKey: Self.readyKey) && isModelOnDisk
    }

    /// Verifies the multilingual-e5-small weights exist in HubApi's default
    /// cache.
    static var isModelOnDisk: Bool {
        let url = huggingFaceCacheRoot()
            .appendingPathComponent("intfloat/multilingual-e5-small", isDirectory: true)
        return directoryHasContents(url)
    }

    /// Downloads (or verifies) the embedding weights with progress reporting
    /// and caches the loaded container.
    func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        tomLog("Search AI: download starting (multilingual-e5-small)")
        let started = Date()
        let configuration = MLXEmbedders.ModelConfiguration.multilingual_e5_small
        let container = try await MLXEmbedders.loadModelContainer(
            configuration: configuration,
            progressHandler: { p in
                progress(p.fractionCompleted)
            }
        )
        self.container = container
        UserDefaults.standard.set(true, forKey: Self.readyKey)
        tomLog("Search AI: download + load complete in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    nonisolated func embed(_ texts: [String]) async throws -> [[Float]] {
        try await runEmbed(texts)
    }

    private func runEmbed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        // Refuse to run inference until the embedder has been explicitly
        // downloaded via Settings/Onboarding. Same rationale as the
        // transcriber and summarizer guards.
        guard Self.isModelReady else {
            throw EmbeddingError.modelNotLoaded
        }
        let container = try await ensureContainer()
        tomLog("Search AI: embedding batch of \(texts.count) text(s)")
        let started = Date()
        let result = await container.perform { (model: EmbeddingModel, tokenizer, pooling) -> [[Float]] in
            // Token-encode each input with special tokens, then pad to the
            // longest sequence in the batch so they can be stacked into one
            // attention pass. Pad ID is the tokenizer's EOS (or 0).
            let encoded: [[Int]] = texts.map {
                tokenizer.encode(text: $0, addSpecialTokens: true)
            }
            let maxLength = encoded.reduce(into: 16) { acc, elem in
                acc = max(acc, elem.count)
            }
            let padId = tokenizer.eosTokenId ?? 0
            let padded = stacked(encoded.map { elem in
                MLXArray(elem + Array(repeating: padId, count: maxLength - elem.count))
            })
            let mask = (padded .!= padId)
            let tokenTypes = MLXArray.zeros(like: padded)

            let pooled = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                normalize: true, applyLayerNorm: true
            )
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
        tomLog("Search AI: batch done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (\(result.count) vectors)")
        return result
    }

    private func ensureContainer() async throws -> MLXEmbedders.ModelContainer {
        if let container { return container }
        if let loadingTask {
            tomLog("Search AI: joining in-flight load")
            return try await loadingTask.value
        }
        tomLog("Search AI: loading model into memory…")
        let started = Date()
        let task = Task<MLXEmbedders.ModelContainer, Error> {
            let configuration = MLXEmbedders.ModelConfiguration.multilingual_e5_small
            return try await MLXEmbedders.loadModelContainer(configuration: configuration)
        }
        self.loadingTask = task
        do {
            let container = try await task.value
            self.container = container
            self.loadingTask = nil
            tomLog("Search AI: loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return container
        } catch {
            self.loadingTask = nil
            tomLog("Search AI: load failed — \(error.localizedDescription)")
            throw error
        }
    }

    /// Releases the cached `ModelContainer` so the embedder's ~120 MB of
    /// weights can be reclaimed. Idempotent. Tiny model so the cold-start
    /// cost on re-load is small (a few seconds), making the
    /// unload-aggressively-and-reload-on-demand pattern cheap here.
    func unload() {
        let wasLoaded = container != nil || loadingTask != nil
        container = nil
        loadingTask = nil
        if wasLoaded {
            tomLog("Search AI: unloaded from memory")
        }
    }
}

// MARK: - Errors

enum EmbeddingError: LocalizedError {
    case emptyResponse
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "Embedding model returned no output."
        case .modelNotLoaded:
            "Embedding model isn't downloaded yet. Open Settings → AI Models and finish the model download first."
        }
    }
}

// MARK: - SIMD Cosine Distance (Accelerate framework)

/// Fast cosine distance using vDSP SIMD operations. Length-mismatched inputs
/// return 1.0 (maximally distant) so leftover OpenAI-era embeddings don't
/// pollute search results after the migration to nomic-embed.
func simdCosineDistance(_ a: [Float], _ b: UnsafeBufferPointer<Float>) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 1.0 }

    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0

    a.withUnsafeBufferPointer { aBuf in
        vDSP_dotpr(aBuf.baseAddress!, 1, b.baseAddress!, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(aBuf.baseAddress!, 1, aBuf.baseAddress!, 1, &normA, vDSP_Length(a.count))
    }
    vDSP_dotpr(b.baseAddress!, 1, b.baseAddress!, 1, &normB, vDSP_Length(b.count))

    let denom = sqrt(normA) * sqrt(normB)
    guard denom > 0 else { return 1.0 }
    return 1.0 - (dot / denom)
}
