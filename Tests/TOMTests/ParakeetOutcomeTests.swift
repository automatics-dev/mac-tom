import FluidAudio
import Foundation
import Testing
@testable import TOM

@Suite("Parakeet result mapping")
struct ParakeetOutcomeTests {

    private func timing(_ token: String, _ id: Int, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: id, startTime: start, endTime: end, confidence: 0.95)
    }

    private func result(text: String, timings: [TokenTiming]?) -> ASRResult {
        ASRResult(
            text: text,
            confidence: 0.95,
            duration: 10,
            processingTime: 0.1,
            tokenTimings: timings
        )
    }

    @Test("Token timings become word-stamped utterance segments")
    func mapsTokensToSegments() {
        // SentencePiece word-boundary marker ▁ starts a new word.
        let timings = [
            timing("▁Hello", 1, 0.0, 0.4),
            timing("▁there", 2, 0.5, 0.9),
            timing("▁every", 3, 1.0, 1.3),
            timing("one", 4, 1.3, 1.6),
        ]
        let outcome = ParakeetTranscriber.outcome(from: result(text: "Hello there everyone", timings: timings))
        #expect(outcome.segments.count == 1)
        #expect(outcome.segments[0].text == "Hello there everyone")
        #expect(outcome.segments[0].words?.map(\.text) == ["Hello", "there", "everyone"])
        #expect(outcome.segments[0].startTime == 0.0)
        #expect(outcome.segments[0].endTime == 1.6)
    }

    @Test("A long pause splits the transcript into two utterances")
    func splitsOnPause() {
        let timings = [
            timing("▁First", 1, 0.0, 0.4),
            timing("▁part", 2, 0.5, 0.9),
            timing("▁Second", 3, 5.0, 5.4),
            timing("▁part", 4, 5.5, 5.9),
        ]
        let outcome = ParakeetTranscriber.outcome(from: result(text: "First part Second part", timings: timings))
        #expect(outcome.segments.count == 2)
        #expect(outcome.segments[0].text == "First part")
        #expect(outcome.segments[1].text == "Second part")
    }

    @Test("Missing timings fall back to one full-duration segment")
    func fallbackWithoutTimings() {
        let outcome = ParakeetTranscriber.outcome(from: result(text: "Some text", timings: nil))
        #expect(outcome.segments.count == 1)
        #expect(outcome.segments[0].words == nil)
        #expect(outcome.segments[0].endTime == 10)
    }

    @Test("Hallucinated no-speech artifacts are dropped")
    func dropsHallucinations() {
        let outcome = ParakeetTranscriber.outcome(from: result(text: "Thank you.", timings: nil))
        #expect(outcome.segments.isEmpty)
    }

    @Test("Empty transcription yields no segments")
    func emptyResult() {
        let outcome = ParakeetTranscriber.outcome(from: result(text: "  ", timings: nil))
        #expect(outcome.segments.isEmpty)
    }
}
