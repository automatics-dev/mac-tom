import CoreGraphics
import Foundation
import Testing
@testable import TOM

@Suite("AI handoff")
struct AIHandoffTests {
    private let meetingId = UUID()

    /// Recordings folder with `count` annotations' screenshots; odd ones
    /// also have a crop.
    private func fixture(_ count: Int) throws -> (root: URL, recordings: URL, annotations: [Annotation]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tom-handoff-test-\(UUID().uuidString)", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let shots = recordings.appendingPathComponent("x.annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        var annotations: [Annotation] = []
        for i in 1...count {
            let full = String(format: "%02d-full.png", i)
            try Data("full\(i)".utf8).write(to: shots.appendingPathComponent(full))
            var a = Annotation(
                meetingId: meetingId, index: i, isMarker: i == count && count > 1,
                startTime: TimeInterval(i * 10), endTime: TimeInterval(i * 10 + 5),
                marks: [AnnotationMark(tool: .box, points: [.zero, CGPoint(x: 20, y: 20)], label: "Item \(i)")],
                screenshotPath: "x.annotations/\(full)"
            )
            if i % 2 == 1 {
                let crop = String(format: "%02d-crop.png", i)
                try Data("crop\(i)".utf8).write(to: shots.appendingPathComponent(crop))
                a.cropPath = "x.annotations/\(crop)"
            }
            annotations.append(a)
        }
        return (root, recordings, annotations)
    }

    private func segment(_ start: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: start + 3, speaker: "Me", text: text)
    }

    @Test func packageHasReviewScreenshotsAndTranscript() throws {
        let (root, recordings, annotations) = try fixture(2)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("out", isDirectory: true)
        let package = try AIHandoff.build(
            title: "Pricing review", date: Date(), annotations: annotations.reversed(),
            segments: [segment(1, "Intro."), segment(11, "Make this orange."), segment(40, "That's all.")],
            recordings: recordings, target: .claude, into: folder
        )

        #expect(package.files.map(\.lastPathComponent) == ["feedback.md", "annotation-01.png", "annotation-01-detail.png", "marker-02.png"])
        #expect(package.omittedImages == 0)
        #expect(package.message.contains("3 screenshots"))
        for file in package.files { #expect(FileManager.default.fileExists(atPath: file.path)) }
        #expect(try String(contentsOf: package.files[1], encoding: .utf8) == "full1")

        let md = try String(contentsOf: package.files[0], encoding: .utf8)
        #expect(md.hasPrefix("I recorded this feedback"))
        #expect(md.contains("# Pricing review"))
        #expect(md.contains("![Annotation 1 detail](annotation-01-detail.png)"))
        #expect(md.contains("![Annotation 1 screenshot](annotation-01.png)"))
        #expect(md.contains("![Marker 2 screenshot](marker-02.png)"))
        #expect(md.contains("- Box: Item 1"))
        #expect(md.contains("**Said:** Make this orange."))
        #expect(md.contains("## Full transcript\n\n[0:01] Intro.\n[0:11] Make this orange.\n[0:40] That's all."))
        #expect(!md.contains("not attached"))
    }

    /// Over the limit: crops go first, then screenshots from the end.
    @Test func respectsFileLimit() throws {
        let (root, recordings, annotations) = try fixture(12)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try AIHandoff.build(
            title: "Long review", date: Date(), annotations: annotations, segments: [],
            recordings: recordings, target: .chatGPT, into: root.appendingPathComponent("out")
        )
        #expect(package.files.count == AIHandoff.Target.chatGPT.fileLimit)
        #expect(package.omittedImages == 3)
        #expect(!package.files.contains { $0.lastPathComponent.contains("detail") })
        #expect(package.files.last?.lastPathComponent == "annotation-09.png")
        let md = try String(contentsOf: package.files[0], encoding: .utf8)
        #expect(md.contains("last 3 annotation(s) are not attached"))
        #expect(md.contains("## Annotation 11"))
        #expect(!md.contains("annotation-11.png"))
        #expect(!md.contains("## Full transcript"))
    }

    /// Crops are kept only when every one fits alongside the screenshots.
    @Test func dropsCropsBeforeScreenshots() throws {
        let (root, recordings, annotations) = try fixture(6)
        defer { try? FileManager.default.removeItem(at: root) }
        // 6 screenshots + 3 crops = 9 = ChatGPT's budget beside the review.
        let fits = try AIHandoff.build(
            title: "R", date: Date(), annotations: annotations, segments: [],
            recordings: recordings, target: .chatGPT, into: root.appendingPathComponent("a")
        )
        #expect(fits.files.count == 10)
        let (root2, recordings2, seven) = try fixture(7)
        defer { try? FileManager.default.removeItem(at: root2) }
        // 7 + 4 = 11 > 9: screenshots only.
        let trimmed = try AIHandoff.build(
            title: "R", date: Date(), annotations: seven, segments: [],
            recordings: recordings2, target: .chatGPT, into: root2.appendingPathComponent("b")
        )
        #expect(trimmed.files.count == 8)
        #expect(trimmed.omittedImages == 0)
    }

    @Test func rebuildReplacesFolder() throws {
        let (root, recordings, annotations) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("stale.png"))
        _ = try AIHandoff.build(title: "R", date: Date(), annotations: annotations, segments: [], recordings: recordings, target: .claude, into: folder)
        _ = try AIHandoff.build(title: "R", date: Date(), annotations: annotations, segments: [], recordings: recordings, target: .claude, into: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["annotation-01-detail.png", "annotation-01.png", "feedback.md"])
    }

    @Test func missingScreenshotFails() throws {
        let (root, recordings, annotations) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: recordings.appendingPathComponent(annotations[0].screenshotPath))
        #expect(throws: (any Error).self) {
            try AIHandoff.build(title: "R", date: Date(), annotations: annotations, segments: [], recordings: recordings, target: .claude, into: root.appendingPathComponent("out"))
        }
    }

    @Test func noAnnotationsStillSendsReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tom-handoff-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try AIHandoff.build(
            title: "R", date: Date(), annotations: [], segments: [segment(0, "Just talking.")],
            recordings: root, target: .claude, into: root.appendingPathComponent("out")
        )
        #expect(package.files.map(\.lastPathComponent) == ["feedback.md"])
        #expect(package.message == "Please implement the feedback in feedback.md.")
        let md = try String(contentsOf: package.files[0], encoding: .utf8)
        #expect(md.contains("**Narration:** Just talking."))
        #expect(md.contains("[0:00] Just talking."))
    }

    @Test func transcriptSkipsBlankSegments() {
        let text = LearningReview.transcript([segment(65, " Second. "), segment(3, "First."), segment(70, "  ")])
        #expect(text == "[0:03] First.\n[1:05] Second.")
    }
}

@Suite("Recording setup")
struct RecordingSetupTests {
    @Test func systemAudioIsPerMode() {
        var setup = RecordingSetup()
        #expect(setup.systemAudio)
        setup.mode = .feedback
        #expect(!setup.systemAudio)
        setup.systemAudio = true
        setup.mode = .meeting
        setup.systemAudio = false
        setup.mode = .feedback
        #expect(setup.systemAudio)
        #expect(setup.captureOptions.systemAudio && setup.captureOptions.microphone)
    }

    @Test func hasAudio() {
        var setup = RecordingSetup()
        setup.microphone = false
        setup.meetingSystemAudio = false
        #expect(!setup.hasAudio)
        setup.mode = .voiceNote
        #expect(setup.hasAudio)
        setup.mode = .feedback
        setup.feedbackSystemAudio = true
        #expect(setup.hasAudio)
    }

    @Test func feedbackKeepsWindowSource() throws {
        var setup = RecordingSetup()
        setup.mode = .feedback
        setup.source = .window
        setup.windowBundleID = "com.google.Chrome"
        let decoded = try JSONDecoder().decode(RecordingSetup.self, from: JSONEncoder().encode(setup))
        #expect(decoded == setup)
        #expect(decoded.source == .window)
    }

    @Test func modeOrder() {
        #expect(RecordingSetup.Mode.allCases == [.meeting, .voiceNote, .feedback])
    }
}
