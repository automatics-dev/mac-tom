import CoreGraphics
import Foundation
import Testing
@testable import TOM

@Suite("Learning review")
struct LearningReviewTests {
    private let meetingId = UUID()

    private func annotation(_ index: Int, _ start: TimeInterval, _ end: TimeInterval, marker: Bool = false, marks: [AnnotationMark] = []) -> Annotation {
        Annotation(
            meetingId: meetingId, index: index, isMarker: marker, startTime: start, endTime: end,
            marks: marks, screenshotPath: "x.annotations/\(String(format: "%02d", index))-full.png"
        )
    }

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String, words: [WordStamp]? = nil) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, speaker: "Me", text: text, words: words)
    }

    @Test func speechSplitsIntoAnnotationsAndNarration() {
        let blocks = LearningReview.blocks(
            annotations: [annotation(1, 10, 20), annotation(2, 40, 50)],
            segments: [
                segment(0, 5, "Intro."),
                segment(12, 18, "This button is wrong."),
                segment(25, 30, "Moving on."),
                segment(42, 48, "Make this bigger."),
                segment(60, 65, "Done."),
            ]
        )
        #expect(blocks.count == 5)
        #expect(blocks[0] == .narration("Intro."))
        guard case .annotation(let first, let speech1) = blocks[1] else { Issue.record("expected annotation"); return }
        #expect(first.index == 1)
        #expect(speech1 == "This button is wrong.")
        #expect(blocks[2] == .narration("Moving on."))
        guard case .annotation(_, let speech2) = blocks[3] else { Issue.record("expected annotation"); return }
        #expect(speech2 == "Make this bigger.")
        #expect(blocks[4] == .narration("Done."))
    }

    /// A segment that straddles the ⌥A press is split by its word timings.
    @Test func wordTimingsSplitAtPress() {
        let words = [
            WordStamp(text: "before", start: 8, end: 9),
            WordStamp(text: "press", start: 9, end: 9.8),
            WordStamp(text: "this", start: 10.2, end: 10.6),
            WordStamp(text: "header", start: 10.6, end: 11.2),
        ]
        let blocks = LearningReview.blocks(
            annotations: [annotation(1, 10, 15)],
            segments: [segment(8, 11.2, "before press this header", words: words)]
        )
        #expect(blocks.first == .narration("before press"))
        guard case .annotation(_, let speech) = blocks.last else { Issue.record("expected annotation"); return }
        #expect(speech == "this header")
    }

    @Test func markerTakesSpeechAroundPress() {
        let blocks = LearningReview.blocks(
            annotations: [annotation(1, 30, 30, marker: true)],
            segments: [segment(10, 12, "Far before."), segment(30.5, 33, "Remember this."), segment(50, 52, "Later.")]
        )
        #expect(blocks.count == 3)
        guard case .annotation(_, let speech) = blocks[1] else { Issue.record("expected annotation"); return }
        #expect(speech == "Remember this.")
    }

    /// Real Parakeet output: the last word is stretched over the pause after
    /// it, past the finish press; a marker's window runs into the next
    /// annotation. Taken from an end-to-end session.
    @Test func stretchedLastWordAndMarkerOverlap() {
        let words: [(Double, Double, String)] = [
            (9.51, 10.15, "slowly."), (10.86, 11.42, "Make"), (11.42, 11.66, "this"), (11.98, 12.30, "button"),
            (12.30, 12.70, "orange."), (13.66, 15.66, "Large."), (17.90, 18.78, "section."), (19.02, 19.58, "Footer"),
            (19.90, 20.62, "broken."), (22.27, 22.59, "Remove"), (22.59, 23.39, "sidebar."), (26.67, 26.91, "Done."),
        ]
        let stamps = words.map { WordStamp(text: $0.2, start: $0.0, end: $0.1) }
        let blocks = LearningReview.blocks(
            annotations: [annotation(1, 10.0, 13.9), annotation(2, 18.1, 18.1, marker: true), annotation(3, 21.5, 24.8)],
            segments: [segment(9.51, 26.91, stamps.map(\.text).joined(separator: " "), words: stamps)]
        )
        let rendered = blocks.map { block -> String in
            switch block {
            case .narration(let text): return "N:" + text
            case .annotation(let a, let speech): return "\(a.index):" + speech
            }
        }
        #expect(rendered == [
            "N:slowly.",
            "1:Make this button orange. Large.",
            "N:section.",
            "2:Footer broken.",
            "3:Remove sidebar.",
            "N:Done.",
        ])
    }

    @Test func annotationWithoutSpeechStillListed() {
        let blocks = LearningReview.blocks(annotations: [annotation(1, 10, 20)], segments: [])
        #expect(blocks.count == 1)
        guard case .annotation(_, let speech) = blocks[0] else { Issue.record("expected annotation"); return }
        #expect(speech.isEmpty)
    }

    @Test func cropRectPadsAndClamps() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let marks = [
            AnnotationMark(tool: .box, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)]),
            AnnotationMark(tool: .arrow, points: [CGPoint(x: 980, y: 10), CGPoint(x: 900, y: 60)]),
        ]
        let rect = Annotation.cropRect(for: marks, in: screen)
        #expect(rect == CGRect(x: 76, y: 0, width: 924, height: 174))
        #expect(Annotation.cropRect(for: [], in: screen) == nil)
        // Label pills above a mark widen the crop.
        let withLabel = Annotation.cropRect(for: [marks[0]], including: [CGRect(x: 100, y: 70, width: 300, height: 20)], in: screen)
        #expect(withLabel == CGRect(x: 76, y: 46, width: 348, height: 128))
    }

    @Test func markdownEmbedsImagesLabelsAndSpeech() {
        let mark = AnnotationMark(tool: .box, points: [.zero, CGPoint(x: 10, y: 10)], label: "Primary CTA")
        let a = annotation(3, 65, 80, marks: [mark])
        let md = LearningReview.markdown(
            title: "Checkout review", date: Date(),
            blocks: [.narration("Overall slow."), .annotation(a, speech: "Make it orange.")]
        ) { _ in ("screens/03-full.png", "screens/03-crop.png") }
        #expect(md.hasPrefix("# Checkout review"))
        #expect(md.contains("> **Narration:** Overall slow."))
        #expect(md.contains("## Annotation 3 · 1:05–1:20"))
        #expect(md.contains("![Annotation 3 detail](screens/03-crop.png)"))
        #expect(md.contains("![Annotation 3 screenshot](screens/03-full.png)"))
        #expect(md.contains("- Box: Primary CTA"))
        #expect(md.contains("**Said:** Make it orange."))
    }

    @Test func timestampFormats() {
        #expect(LearningReview.timestamp(5) == "0:05")
        #expect(LearningReview.timestamp(605) == "10:05")
        #expect(LearningReview.timestamp(3725) == "1:02:05")
    }

    @Test func specFolderLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tom-spec-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let shots = recordings.appendingPathComponent("x.annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("full".utf8).write(to: shots.appendingPathComponent("01-full.png"))
        try Data("crop".utf8).write(to: shots.appendingPathComponent("01-crop.png"))

        var a = annotation(1, 10, 20, marks: [AnnotationMark(tool: .box, points: [.zero, CGPoint(x: 5, y: 5)])])
        a.cropPath = "x.annotations/01-crop.png"
        let folder = root.appendingPathComponent("Review spec", isDirectory: true)
        try LearningReview.writeSpecFolder(
            to: folder, title: "Review", date: Date(), annotations: [a],
            segments: [segment(12, 14, "Fix this.")], recordings: recordings
        )

        let md = try String(contentsOf: folder.appendingPathComponent("review.md"), encoding: .utf8)
        #expect(md.contains("](screens/01-crop.png)"))
        #expect(md.contains("**Said:** Fix this."))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("screens/01-full.png").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("screens/01-crop.png").path))

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("annotations.json"))) as? [[String: Any]]
        #expect(json?.count == 1)
        #expect(json?.first?["speech"] as? String == "Fix this.")
        #expect(json?.first?["crop"] as? String == "screens/01-crop.png")
    }

    @Test func annotationsRoundTripThroughStorage() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tom-ann-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = StorageManager(home: home)
        let meeting = try storage.createMeeting(title: "Review", kind: .learning)
        let mark = AnnotationMark(tool: .freehand, points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4), CGPoint(x: 5, y: 6)], label: "here")
        let saved = Annotation(
            meetingId: meeting.id, index: 1, isMarker: false, startTime: 1.5, endTime: 4,
            marks: [mark], screenshotPath: "a/01-full.png", cropPath: "a/01-crop.png"
        )
        try storage.saveAnnotation(saved)

        #expect(try storage.fetchAnnotations(meetingId: meeting.id) == [saved])
        #expect(try storage.fetchMeeting(id: meeting.id)?.kind == .learning)
        try storage.deleteMeeting(id: meeting.id)
        #expect(try storage.fetchAnnotations(meetingId: meeting.id).isEmpty)
    }
}

@Suite("Continuous transcript")
struct ContinuousTranscriptTests {
    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, speaker: "Me", text: text, words: nil)
    }

    @Test("Segments run together; a pause starts a paragraph; blanks are skipped")
    func paragraphs() {
        let text = ContinuousTranscript.attributed([
            segment(0, 4, "Right, so the app works"),
            segment(4.5, 6, " but needs changes. "),
            segment(6, 7, "  "),
            segment(12, 15, "See the settings."),
        ], currentIndex: 1)
        #expect(String(text.characters) == "Right, so the app works but needs changes.\n\nSee the settings.")
    }
}
