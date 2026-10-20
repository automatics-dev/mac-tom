import Foundation
import Testing
@testable import TOM

@Suite("Streaming silence gate")
struct SilenceGateTests {

    @Test("Digital silence is detected")
    func detectsSilence() {
        let silence = [Float](repeating: 0, count: 16_000)
        #expect(StreamingTranscriptionSession.isMostlySilence(silence))
    }

    @Test("Room-hiss-level noise is still silence")
    func detectsHiss() {
        let hiss = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
        #expect(StreamingTranscriptionSession.isMostlySilence(hiss))
    }

    @Test("Speech-level energy is not silence")
    func detectsSpeech() {
        // 440 Hz tone at speech-typical amplitude.
        let tone = (0..<16_000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16_000.0))
        }
        #expect(!StreamingTranscriptionSession.isMostlySilence(tone))
    }
}

@Suite("Silence-aware chunk cutting")
struct SilenceCutIndexTests {

    @Test("Cut lands inside a silent stretch near the target")
    func cutsAtSilence() {
        let rate = 16_000
        // 8 s tone, 1 s silence, 6 s tone. Target cut at 10 s should snap
        // back into the silent stretch (8–9 s window).
        var samples = (0..<(8 * rate)).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / Double(rate)))
        }
        samples += [Float](repeating: 0, count: rate)
        samples += (0..<(6 * rate)).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / Double(rate)))
        }

        let cut = StreamingTranscriptionSession.silenceCutIndex(
            in: samples, target: 10 * rate, sampleRate: rate
        )
        #expect(cut >= 8 * rate)
        #expect(cut <= 9 * rate + rate / 10)
    }

    @Test("Cut never exceeds the sample count")
    func boundedCut() {
        let samples = [Float](repeating: 0.05, count: 1000)
        let cut = StreamingTranscriptionSession.silenceCutIndex(
            in: samples, target: 5000, sampleRate: 16_000
        )
        #expect(cut <= samples.count)
        #expect(cut > 0)
    }
}

@Suite("Live audio mixer")
struct LiveAudioMixerTests {

    @Test("Aligned inputs are summed sample by sample")
    func sumsAlignedInputs() {
        var mixer = LiveAudioMixer(inputs: ["system", "mic"], maxLagSamples: 100)
        #expect(mixer.append([0.1, 0.2, 0.3], from: "system").isEmpty)
        let out = mixer.append([0.1, 0.1, 0.1], from: "mic")
        #expect(out.count == 3)
        for (got, want) in zip(out, [Float(0.2), 0.3, 0.4]) {
            #expect(abs(got - want) < 1e-6)
        }
    }

    @Test("Only the overlap is emitted; the longer input's extra waits")
    func holdsUnmatchedSamples() {
        var mixer = LiveAudioMixer(inputs: ["system", "mic"], maxLagSamples: 100)
        _ = mixer.append([Float](repeating: 0.1, count: 10), from: "system")
        #expect(mixer.append([Float](repeating: 0.1, count: 4), from: "mic").count == 4)
        #expect(mixer.append([Float](repeating: 0.1, count: 6), from: "mic").count == 6)
    }

    @Test("A stalled input is padded with silence once it lags too far")
    func padsStalledInput() {
        var mixer = LiveAudioMixer(inputs: ["system", "mic"], maxLagSamples: 5)
        // System delivers nothing (e.g. SCK sends no buffers while silent);
        // the mic must not be held hostage beyond the lag budget.
        let out = mixer.append([Float](repeating: 0.2, count: 12), from: "mic")
        #expect(out.count == 7)
        #expect(out.allSatisfy { abs($0 - 0.2) < 1e-6 })
    }

    @Test("Sum is clamped to [-1, 1]")
    func clampsSum() {
        var mixer = LiveAudioMixer(inputs: ["system", "mic"], maxLagSamples: 100)
        _ = mixer.append([0.8, -0.8], from: "system")
        let out = mixer.append([0.8, -0.8], from: "mic")
        #expect(out == [1, -1])
    }

    @Test("Flush emits everything still buffered, padding the shorter input")
    func flushDrains() {
        var mixer = LiveAudioMixer(inputs: ["system", "mic"], maxLagSamples: 100)
        _ = mixer.append([0.1, 0.1, 0.1], from: "system")
        let out = mixer.flush()
        #expect(out.count == 3)
        #expect(mixer.flush().isEmpty)
    }

    @Test("Unknown sources are ignored")
    func ignoresUnknownSource() {
        var mixer = LiveAudioMixer(inputs: ["system", "mic"], maxLagSamples: 100)
        #expect(mixer.append([0.5], from: "other").isEmpty)
        #expect(mixer.flush().isEmpty)
    }
}
