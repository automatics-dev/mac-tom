import AVFoundation
import CoreMedia
import Foundation

// MARK: - Live Transcription Preference

/// Whether TOM transcribes audio live *during* recording. Keeping Whisper
/// resident while the recorder drives H.264 encoding costs ~1.5–2 GB of
/// unified memory, so the default is on only for machines with enough
/// headroom; the Settings toggle overrides in either direction.
enum LiveTranscription {
    static let key = "tom.liveTranscribeWhileRecording"

    static var isEnabled: Bool {
        if let explicit = UserDefaults.standard.object(forKey: key) as? Bool { return explicit }
        return ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

// MARK: - Streaming Transcription Session

/// Transcribes a recording *while it is being captured*. Audio taps feed
/// 16 kHz mono samples per source ("system", "mic"); once a source
/// accumulates ~30 s the session cuts a chunk at the quietest point near the
/// boundary and runs it through Whisper immediately. By the time the user
/// hits Stop, everything but the tail is already transcribed — `finish()`
/// flushes the tail and hands back final segments, and the post-recording
/// pipeline skips its full-file Whisper pass entirely.
///
/// With Parakeet, the primary source also gets a rolling preview: every
/// ~0.5 s of new audio the uncommitted tail is re-decoded and pushed as
/// volatile text, so words appear about a second after they are spoken. The
/// preview is display-only — committed chunks remain the source of truth.
///
/// Failure is never fatal: any transcription error marks the session failed,
/// `finish()` returns nil, and the caller falls back to the classic
/// transcribe-after-stop pipeline against the files on disk.
actor StreamingTranscriptionSession {

    /// One push to the live view: utterances that just became final, plus the
    /// replacement volatile tail (nil = leave as is, "" = clear). Delivered as
    /// one value so a commit and the matching tail reset can't reorder.
    struct LiveUpdate: Sendable {
        var committed: [String] = []
        var preview: String?
    }

    static let sampleRate = 16_000

    /// Engine resolved once at session start — a mid-recording settings
    /// change applies to the next recording, not this one.
    private let engine = TranscriptionEngine.selected

    /// Chunk size target. Whisper: 30 s matches its native window, so
    /// per-chunk quality equals the full-file pass. Parakeet decodes ~110×
    /// realtime with no fixed window, so smaller chunks are nearly free and
    /// the live preview updates twice as often.
    private var chunkSamples: Int {
        (engine == .parakeet ? 15 : 30) * Self.sampleRate
    }

    /// The very first chunk of each source is cut early so the user sees
    /// words within seconds of starting, not after half a minute.
    private var firstChunkSamples: Int {
        (engine == .parakeet ? 5 : 10) * Self.sampleRate
    }

    /// Tails shorter than this are dropped at finish — Whisper on <0.5 s of
    /// audio yields nothing but hallucination risk.
    private let minTailSamples = StreamingTranscriptionSession.sampleRate / 2

    /// Rolling preview cadence: re-decode the primary tail each time this much
    /// new audio has arrived. Parakeet decodes a 15 s tail in ~0.15 s on the
    /// ANE, so 0.5 s keeps the preview near real time at modest load.
    private let previewStrideSamples = StreamingTranscriptionSession.sampleRate / 2
    /// Shortest tail worth previewing — sub-second audio decodes to noise.
    private let minPreviewSamples = StreamingTranscriptionSession.sampleRate
    private var previewBusy = false
    /// Absolute sample position covered by the last preview started.
    private var previewedThrough = 0

    private struct Source {
        let label: String            // speaker label for produced segments
        var pending: [Float] = []    // samples not yet transcribed
        var consumedSamples = 0      // timeline offset of pending[0]
        var segments: [TranscriptSegment] = []
        var busy = false             // a chunk of this source is in-flight
    }

    private var sources: [String: Source]
    /// Source whose text feeds the live preview. Only one streams to the UI —
    /// interleaving two concurrently-decoded sources garbles the reading flow.
    private let primaryKey: String
    private let onLiveUpdate: @Sendable (LiveUpdate) -> Void
    private var detectedLanguage: String?
    private(set) var failed = false
    private var finishing = false
    /// Last text pushed to the live preview — consecutive identical
    /// utterances ("Thank you." × N from silence hallucination) collapse to
    /// one line on screen.
    private var lastLiveText = ""
    /// Taps mixed down into the primary source before decoding, or nil when
    /// each tap is its own source.
    private var mixer: LiveAudioMixer?

    /// - Parameters:
    ///   - sources: source key → speaker label, e.g. `["mixed": "Speaker"]`.
    ///   - mixing: tap keys summed into `primary` instead of being decoded
    ///     separately — one voice reaching both mic and system audio is then
    ///     transcribed once, not twice under two labels.
    init(
        sources: [String: String],
        primary: String,
        mixing: [String] = [],
        onLiveUpdate: @escaping @Sendable (LiveUpdate) -> Void
    ) {
        self.sources = sources.mapValues { Source(label: $0) }
        self.primaryKey = primary
        // 1 s lag budget: taps drift by milliseconds, but SCK may deliver no
        // system buffers at all while nothing plays.
        self.mixer = mixing.isEmpty ? nil : LiveAudioMixer(inputs: mixing, maxLagSamples: Self.sampleRate)
        self.onLiveUpdate = onLiveUpdate
    }

    // MARK: Ingest

    /// Append converted samples from an audio tap. Cheap unless a chunk
    /// boundary is crossed, in which case a transcription Task is spawned.
    func append(_ samples: [Float], source key: String) {
        guard !failed, !finishing else { return }
        if mixer?.inputs.contains(key) == true {
            let mixed = mixer!.append(samples, from: key)
            if !mixed.isEmpty { ingest(mixed, key: primaryKey) }
        } else {
            ingest(samples, key: key)
        }
    }

    private func ingest(_ samples: [Float], key: String) {
        guard sources[key] != nil else { return }
        sources[key]!.pending.append(contentsOf: samples)
        maybeProcessChunk(key)
        if key == primaryKey { maybePreview() }
    }

    // MARK: Rolling Preview

    /// Re-decodes the primary source's uncommitted tail when enough new audio
    /// has arrived. Skipped while a primary chunk is in flight: its words are
    /// neither in `pending` nor committed yet, so a preview would drop them.
    private func maybePreview() {
        guard engine == .parakeet, !previewBusy, !failed, !finishing,
              let src = sources[primaryKey], !src.busy,
              src.pending.count >= minPreviewSamples else { return }
        let end = src.consumedSamples + src.pending.count
        guard end - previewedThrough >= previewStrideSamples else { return }
        previewedThrough = end
        previewBusy = true
        let tail = src.pending
        let generation = src.consumedSamples
        Task { await self.runPreview(tail, generation: generation) }
    }

    private func runPreview(_ tail: [Float], generation: Int) async {
        defer { previewBusy = false }
        // Quiet tail: keep the current preview rather than blanking it.
        guard !Self.isMostlySilence(tail),
              let outcome = try? await engine.transcribeSamples(tail) else { return }
        // A chunk committed while this decoded — its words are already final,
        // so this preview would show them twice.
        guard !failed, !finishing, sources[primaryKey]?.consumedSamples == generation else { return }
        let text = outcome.segments.map(\.text).joined(separator: " ")
        onLiveUpdate(LiveUpdate(preview: text))
    }

    private func maybeProcessChunk(_ key: String) {
        guard let src = sources[key], !src.busy else { return }
        let target = src.consumedSamples == 0 ? firstChunkSamples : chunkSamples
        guard src.pending.count >= target else { return }
        let cut = Self.silenceCutIndex(in: src.pending, target: target, sampleRate: Self.sampleRate)
        let chunk = Array(sources[key]!.pending[..<cut])
        sources[key]!.pending.removeFirst(cut)
        let offsetSeconds = Double(src.consumedSamples) / Double(Self.sampleRate)
        sources[key]!.consumedSamples += cut
        sources[key]!.busy = true
        Task { await self.process(chunk: chunk, offsetSeconds: offsetSeconds, key: key) }
    }

    private func process(chunk: [Float], offsetSeconds: Double, key: String) async {
        // Silence gate: don't run Whisper on audio with no speech energy.
        // A silent stream (muted mic while recording a video, quiet stretch
        // of a meeting) is exactly where Whisper hallucinates its
        // "Thank you. Thank you." YouTube-outro loops — skipping the decode
        // kills those at the source and saves the compute.
        guard !Self.isMostlySilence(chunk) else {
            if key == primaryKey, engine == .parakeet { onLiveUpdate(LiveUpdate(preview: "")) }
            chunkDone(key)
            return
        }
        do {
            let outcome = try await engine.transcribeSamples(chunk)
            if detectedLanguage == nil { detectedLanguage = outcome.language }
            let label = sources[key]?.label ?? "Speaker"
            let shifted = outcome.segments.map { seg in
                TranscriptSegment(
                    startTime: seg.startTime + offsetSeconds,
                    endTime: seg.endTime + offsetSeconds,
                    speaker: label,
                    text: seg.text,
                    words: seg.words?.map {
                        WordStamp(text: $0.text, start: $0.start + offsetSeconds, end: $0.end + offsetSeconds)
                    }
                )
            }
            sources[key]?.segments.append(contentsOf: shifted)
            if key == primaryKey {
                var update = LiveUpdate()
                for seg in shifted where seg.text != lastLiveText {
                    update.committed.append(seg.text)
                    lastLiveText = seg.text
                }
                // The old tail covered these words; the next preview redraws
                // whatever is still uncommitted.
                if engine == .parakeet { update.preview = "" }
                if !update.committed.isEmpty || update.preview != nil { onLiveUpdate(update) }
            }
        } catch {
            tomLog("Live transcription: chunk failed (\(key), offset \(Int(offsetSeconds))s) — \(error.localizedDescription). Falling back to post-stop transcription.")
            failed = true
            onLiveUpdate(LiveUpdate(preview: ""))
        }
        chunkDone(key)
    }

    private func chunkDone(_ key: String) {
        sources[key]?.busy = false
        maybeProcessChunk(key)
        if key == primaryKey {
            previewedThrough = 0   // redraw the remaining tail right away
            maybePreview()
        }
    }

    // MARK: Finish

    /// Flushes the pending tails, waits for in-flight chunks, and returns the
    /// final ordered segments — or nil if streaming failed at any point (the
    /// caller then runs the classic full-file pipeline).
    func finish() async -> TranscriptionOutcome? {
        finishing = true

        // Wait out in-flight chunk tasks. Bounded: each chunk takes a few
        // seconds; polling on the actor lets `process` re-enter and finish.
        while sources.values.contains(where: { $0.busy }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard !failed else { return nil }

        if let rest = mixer?.flush(), !rest.isEmpty {
            sources[primaryKey]?.pending.append(contentsOf: rest)
        }

        for key in sources.keys {
            let src = sources[key]!
            guard src.pending.count >= minTailSamples else { continue }
            let tail = src.pending
            let offsetSeconds = Double(src.consumedSamples) / Double(Self.sampleRate)
            sources[key]!.pending = []
            sources[key]!.consumedSamples += tail.count
            await process(chunk: tail, offsetSeconds: offsetSeconds, key: key)
        }

        guard !failed else { return nil }

        // Utterance-fold per source (folding must not merge across speakers),
        // then filter hallucinations AT THE UTTERANCE LEVEL — the per-chunk
        // filter can't catch "Thank you." repeated across many short
        // segments, but once folded into one utterance the repetition is
        // obvious. Mirrors the classic pipeline's group-then-filter order.
        let folded = sources.values.flatMap { src in
            WhisperKitTranscriber.groupBySilenceGaps(src.segments.sorted { $0.startTime < $1.startTime })
        }
        let filtered = folded.filter { seg in
            guard WhisperKitTranscriber.isHallucination(seg.text) else { return true }
            tomLog("Live transcription: dropped hallucinated utterance (\(seg.text.count) chars): \(String(seg.text.prefix(80)))")
            return false
        }
        let merged = filtered.sorted { $0.startTime < $1.startTime }
        tomLog("Live transcription: session finished with \(merged.count) segments (language=\(detectedLanguage ?? "unknown"))")
        return TranscriptionOutcome(segments: merged, language: detectedLanguage)
    }

    /// True when the chunk carries no speech-level energy. RMS of normal
    /// speech at 16 kHz float sits well above 0.01; a muted or absent stream
    /// idles around 1e-4. Threshold 0.004 leaves generous margin for quiet
    /// speakers while catching digital silence and room hiss.
    static func isMostlySilence(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms < 0.004
    }

    // MARK: Silence-aware chunk boundary

    /// Index at which to cut a chunk: the start of the quietest 0.3 s window
    /// within the last 5 s before `target`. Cutting mid-word splits a word
    /// across chunks and degrades both halves; speech pauses are frequent
    /// enough that this almost always finds a clean boundary.
    static func silenceCutIndex(in samples: [Float], target: Int, sampleRate: Int) -> Int {
        let searchWindow = 5 * sampleRate
        let rmsWindow = (3 * sampleRate) / 10
        let stride = sampleRate / 10
        let searchStart = max(0, target - searchWindow)
        guard target <= samples.count, searchStart + rmsWindow < target else {
            return min(target, samples.count)
        }

        var bestIdx = target
        var bestEnergy = Float.greatestFiniteMagnitude
        var idx = searchStart
        while idx + rmsWindow <= target {
            var energy: Float = 0
            for s in samples[idx ..< idx + rmsWindow] { energy += s * s }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIdx = idx + rmsWindow / 2   // cut mid-silence, not at its edge
            }
            idx += stride
        }
        return bestIdx
    }
}

// MARK: - Live Audio Mixer

/// Sums several 16 kHz mono taps into one stream, sample-aligned by arrival.
/// Emits only the span every input has delivered; an input lagging more than
/// `maxLagSamples` behind the furthest one is padded with silence so a tap
/// that stops delivering can't stall the others.
struct LiveAudioMixer {
    let inputs: [String]
    private let maxLagSamples: Int
    private var queues: [String: [Float]]

    init(inputs: [String], maxLagSamples: Int) {
        self.inputs = inputs
        self.maxLagSamples = maxLagSamples
        self.queues = Dictionary(uniqueKeysWithValues: inputs.map { ($0, []) })
    }

    /// Adds samples from one input; returns newly mixed samples (may be empty).
    mutating func append(_ samples: [Float], from input: String) -> [Float] {
        guard queues[input] != nil else { return [] }
        queues[input]!.append(contentsOf: samples)
        let longest = queues.values.map(\.count).max() ?? 0
        for key in inputs where queues[key]!.count < longest - maxLagSamples {
            queues[key]!.append(contentsOf: repeatElement(0, count: longest - maxLagSamples - queues[key]!.count))
        }
        return drain(queues.values.map(\.count).min() ?? 0)
    }

    /// Mixes out everything still buffered, padding shorter inputs.
    mutating func flush() -> [Float] {
        drain(queues.values.map(\.count).max() ?? 0)
    }

    private mutating func drain(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for key in inputs {
            let q = queues[key]!
            for i in 0..<min(count, q.count) { out[i] += q[i] }
            queues[key]!.removeFirst(min(count, q.count))
        }
        return out.map { min(1, max(-1, $0)) }
    }
}

// MARK: - Streaming Format Converter

/// Converts tap buffers (any device/SCK format) to the 16 kHz mono Float32
/// stream the session ingests. One instance per audio source; not
/// thread-safe by itself, but each tap delivers on its own serial queue.
final class StreamingFormatConverter {

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(StreamingTranscriptionSession.sampleRate),
            channels: 1,
            interleaved: false
        ), let conv = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        outputFormat = out
        converter = conv
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

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
        guard status != .error, error == nil,
              outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    /// Copies an SCK audio sample buffer into an `AVAudioPCMBuffer` so it can
    /// go through `AVAudioConverter`. Returns nil for non-audio buffers.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }
}
