import Foundation
import Testing
@testable import TOM

@Suite("Silence-gap utterance folding")
struct SilenceGapFoldingTests {

    private func seg(_ start: TimeInterval, _ end: TimeInterval, _ text: String, words: [WordStamp]? = nil) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, speaker: "Speaker", text: text, words: words)
    }

    @Test("Segments within the gap fold into one utterance")
    func foldsWithinGap() {
        let folded = WhisperKitTranscriber.groupBySilenceGaps([
            seg(0, 2, "Hello"),
            seg(2.5, 4, "there"),
            seg(4.2, 6, "everyone"),
        ])
        #expect(folded.count == 1)
        #expect(folded[0].text == "Hello there everyone")
        #expect(folded[0].startTime == 0)
        #expect(folded[0].endTime == 6)
    }

    @Test("A gap beyond the threshold starts a new utterance")
    func splitsOnGap() {
        let folded = WhisperKitTranscriber.groupBySilenceGaps([
            seg(0, 2, "First part"),
            seg(5, 7, "Second part"),
        ])
        #expect(folded.count == 2)
        #expect(folded[0].text == "First part")
        #expect(folded[1].text == "Second part")
    }

    @Test("Word stamps are concatenated across folded segments")
    func preservesWordStamps() {
        let folded = WhisperKitTranscriber.groupBySilenceGaps([
            seg(0, 1, "Hello", words: [WordStamp(text: "Hello", start: 0, end: 1)]),
            seg(1.2, 2, "world", words: [WordStamp(text: "world", start: 1.2, end: 2)]),
        ])
        #expect(folded.count == 1)
        #expect(folded[0].words?.map(\.text) == ["Hello", "world"])
    }

    @Test("Custom gap threshold is honoured")
    func customGap() {
        let segments = [seg(0, 1, "a"), seg(3, 4, "b")]
        #expect(WhisperKitTranscriber.groupBySilenceGaps(segments, gapSeconds: 1.0).count == 2)
        #expect(WhisperKitTranscriber.groupBySilenceGaps(segments, gapSeconds: 5.0).count == 1)
    }

    @Test("Empty input yields empty output")
    func emptyInput() {
        #expect(WhisperKitTranscriber.groupBySilenceGaps([]).isEmpty)
    }
}
