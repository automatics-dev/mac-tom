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
