import CoreGraphics
import Foundation

// MARK: - Annotation Model

/// One shape drawn on the Learning overlay. Points are display-local, in
/// points, top-left origin — the same space as the saved screenshots.
struct AnnotationMark: Codable, Equatable, Sendable {
    enum Tool: String, Codable, CaseIterable, Sendable {
        case box, arrow, freehand
    }

    var tool: Tool
    /// box: two opposite corners; arrow: tail then head; freehand: the path.
    var points: [CGPoint]
    var label: String?

    var bounds: CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }
}

/// An annotation round (⌥A … ⌥A) or a marker (⌥M) in a Learning session.
/// Times are seconds from the start of the recording.
struct Annotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var meetingId: UUID
    /// 1-based position in the session; drives screenshot file names.
    var index: Int
    var isMarker: Bool
    var startTime: TimeInterval
    var endTime: TimeInterval
    var marks: [AnnotationMark]
    /// Paths relative to the recordings directory.
    var screenshotPath: String
    var cropPath: String?

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        index: Int,
        isMarker: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval,
        marks: [AnnotationMark],
        screenshotPath: String,
        cropPath: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.index = index
        self.isMarker = isMarker
        self.startTime = startTime
        self.endTime = endTime
        self.marks = marks
        self.screenshotPath = screenshotPath
        self.cropPath = cropPath
    }

    /// The span whose speech belongs to this annotation. A marker has no
    /// finish press, so it takes what's said in the seconds after the press.
    var speechWindow: ClosedRange<TimeInterval> {
        startTime...(isMarker ? startTime + Self.markerTail : max(startTime, endTime))
    }

    static let markerTail: TimeInterval = 8

    /// Crop rectangle around all marks (and `extra` rects such as their
    /// label pills): the bounding box plus `padding`, clamped to `screen`.
    /// nil for markers and empty rounds.
    static func cropRect(
        for marks: [AnnotationMark],
        including extra: [CGRect] = [],
        in screen: CGRect,
        padding: CGFloat = 24
    ) -> CGRect? {
        guard !marks.isEmpty else { return nil }
        let union = (marks.map(\.bounds) + extra).filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return nil }
        let padded = union.insetBy(dx: -padding, dy: -padding).intersection(screen)
        return padded.isNull || padded.isEmpty ? nil : padded.integral
    }
}

// MARK: - Review Builder

/// Merges a Learning session's transcript with its annotations into the
/// review the coding agent reads: annotations in time order, each with the
/// speech spoken during it, and the rest of the speech as narration between.
enum LearningReview {

    enum Block: Equatable {
        case narration(String)
        case annotation(Annotation, speech: String)
    }

    /// Word timings are used when present so speech splits exactly at the
    /// ⌥A presses; segments without them are assigned as a whole. A word
    /// belongs where it *starts* — decoders stretch a phrase's last word
    /// over the following pause, past the finish press. Annotation rounds
    /// win over a marker's window when they overlap.
    static func blocks(annotations: [Annotation], segments: [TranscriptSegment]) -> [Block] {
        let ordered = annotations.sorted { $0.startTime < $1.startTime }
        var speech: [UUID: [String]] = [:]
        // Narration runs, keyed by the index of the annotation they follow
        // (-1 = before the first one).
        var narration: [Int: [String]] = [:]

        for piece in pieces(from: segments) {
            let t = piece.start
            let owner = ordered.first { !$0.isMarker && $0.speechWindow.contains(t) }
                ?? ordered.first { $0.isMarker && $0.speechWindow.contains(t) }
            if let owner {
                speech[owner.id, default: []].append(piece.text)
            } else {
                let after = ordered.lastIndex(where: { $0.startTime <= t }) ?? -1
                narration[after, default: []].append(piece.text)
            }
        }

        var result: [Block] = []
        if let lead = narration[-1] { result.append(.narration(join(lead))) }
        for (i, annotation) in ordered.enumerated() {
            result.append(.annotation(annotation, speech: join(speech[annotation.id] ?? [])))
            if let tail = narration[i] { result.append(.narration(join(tail))) }
        }
        return result
    }

    /// The review as Markdown. `image` maps an annotation to the relative
    /// paths of its screenshot and crop as they'll appear next to the file;
    /// nil leaves that image out.
    static func markdown(
        title: String,
        date: Date,
        blocks: [Block],
        image: (Annotation) -> (full: String?, crop: String?)
    ) -> String {
        var md = "# \(title)\n\n"
        md += "Review recorded \(shortDateFormatter.string(from: date)). Each annotation shows what was marked on screen and what was said while marking it; narration is the commentary in between.\n"
        for block in blocks {
            switch block {
            case .narration(let text):
                md += "\n> **Narration:** \(text)\n"
            case .annotation(let annotation, let speech):
                let kind = annotation.isMarker ? "Marker" : "Annotation"
                md += "\n## \(kind) \(annotation.index) · \(timestamp(annotation.startTime))"
                if !annotation.isMarker { md += "–\(timestamp(annotation.endTime))" }
                md += "\n\n"
                let paths = image(annotation)
                if let crop = paths.crop { md += "![\(kind) \(annotation.index) detail](\(crop))\n\n" }
                if let full = paths.full { md += "![\(kind) \(annotation.index) screenshot](\(full))\n\n" }
                let labels = annotation.marks.compactMap { mark -> String? in
                    guard let label = mark.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                    return "- \(mark.tool.rawValue.capitalized): \(label)"
                }
                if !labels.isEmpty { md += "**Labels**\n" + labels.joined(separator: "\n") + "\n\n" }
                md += speech.isEmpty ? "_No speech during this annotation._\n" : "**Said:** \(speech)\n"
            }
        }
        return md
    }

    /// Writes the hand-off folder for a coding agent: `review.md`,
    /// `screens/NN-full.png` + `NN-crop.png`, and `annotations.json`.
    /// `recordings` is where the annotations' relative image paths resolve.
    static func writeSpecFolder(
        to folder: URL,
        title: String,
        date: Date,
        annotations: [Annotation],
        segments: [TranscriptSegment],
        recordings: URL
    ) throws {
        let fm = FileManager.default
        let screens = folder.appendingPathComponent("screens", isDirectory: true)
        try fm.createDirectory(at: screens, withIntermediateDirectories: true)

        var exported: [String: (full: String, crop: String?)] = [:]
        for annotation in annotations {
            let full = "screens/" + (annotation.screenshotPath as NSString).lastPathComponent
            try fm.copyItem(at: recordings.appendingPathComponent(annotation.screenshotPath), to: folder.appendingPathComponent(full))
            var crop: String?
            if let cropPath = annotation.cropPath {
                crop = "screens/" + (cropPath as NSString).lastPathComponent
                try fm.copyItem(at: recordings.appendingPathComponent(cropPath), to: folder.appendingPathComponent(crop!))
            }
            exported[annotation.id.uuidString] = (full, crop)
        }

        let reviewBlocks = blocks(annotations: annotations, segments: segments)
        let md = markdown(title: title, date: date, blocks: reviewBlocks) {
            let paths = exported[$0.id.uuidString] ?? ($0.screenshotPath, $0.cropPath)
            return (paths.full, paths.crop)
        }
        try md.write(to: folder.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)

        let records = reviewBlocks.compactMap { block -> ExportedAnnotation? in
            guard case .annotation(let a, let speech) = block else { return nil }
            let paths = exported[a.id.uuidString] ?? (a.screenshotPath, a.cropPath)
            return ExportedAnnotation(
                index: a.index, kind: a.isMarker ? "marker" : "annotation",
                start: (a.startTime * 100).rounded() / 100, end: (a.endTime * 100).rounded() / 100,
                marks: a.marks, speech: speech,
                screenshot: paths.full, crop: paths.crop
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(records).write(to: folder.appendingPathComponent("annotations.json"))
    }

    private struct ExportedAnnotation: Encodable {
        let index: Int
        let kind: String
        let start: TimeInterval
        let end: TimeInterval
        let marks: [AnnotationMark]
        let speech: String
        let screenshot: String
        let crop: String?
    }

    /// The whole transcript, one timestamped line per segment.
    static func transcript(_ segments: [TranscriptSegment]) -> String {
        segments.sorted { $0.startTime < $1.startTime }
            .map { "[\(timestamp($0.startTime))] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .filter { !$0.hasSuffix("] ") }
            .joined(separator: "\n")
    }

    /// "m:ss", or "h:mm:ss" past an hour.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private struct Piece {
        let start: TimeInterval
        let text: String
    }

    private static func pieces(from segments: [TranscriptSegment]) -> [Piece] {
        segments.sorted { $0.startTime < $1.startTime }.flatMap { segment -> [Piece] in
            if let words = segment.words, !words.isEmpty {
                return words.map { Piece(start: $0.start, text: $0.text) }
            }
            return [Piece(start: segment.startTime, text: segment.text)]
        }
    }

    private static func join(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
