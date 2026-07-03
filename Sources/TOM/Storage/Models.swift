import Foundation

// MARK: - Meeting Group

struct MeetingGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String  // SF Symbol name (e.g. "folder") or legacy emoji

    init(id: UUID = UUID(), name: String, icon: String = "folder") {
        self.id = id
        self.name = name
        self.icon = icon
    }
}

// MARK: - Meeting

struct Meeting: Identifiable, Codable {
    let id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var recordingPath: String  // relative path in ~/.tom/data/recordings/
    var transcript: String?
    var summary: String?
    var state: MeetingState
    var groupId: UUID?
    var kind: MeetingKind
    /// Per-meeting speaker rename map. Keys are the raw labels stored in
    /// `transcript_segments.speaker` ("Speaker 1", "Speaker 2", "Me", ...);
    /// values are the user-chosen display names ("Anil", "John"). "Me" is
    /// reserved and never aliased.
    var speakerAliases: [String: String]

    init(
        id: UUID = UUID(),
        title: String,
        date: Date = Date(),
        duration: TimeInterval = 0,
        recordingPath: String = "",
        transcript: String? = nil,
        summary: String? = nil,
        state: MeetingState = .recording,
        groupId: UUID? = nil,
        kind: MeetingKind = .meeting,
        speakerAliases: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.recordingPath = recordingPath
        self.transcript = transcript
        self.summary = summary
        self.state = state
        self.groupId = groupId
        self.kind = kind
        self.speakerAliases = speakerAliases
    }
}

// MARK: - Meeting Alias Helpers

extension Meeting {
    /// Summary text with raw speaker labels substituted by the user's chosen
    /// aliases. Use anywhere a human will read the text (Summary tab UI,
    /// clipboard copy, markdown export). Stored `summary` keeps raw labels so
    /// renames stay reversible without re-calling the AI.
    var aliasedSummary: String? {
        guard let summary, !speakerAliases.isEmpty else { return summary }
        return Self.applyAliases(summary, aliases: speakerAliases)
    }

    /// Transcript text with aliases applied, mirroring `aliasedSummary`. Used
    /// as a fallback in the Transcript tab when segments aren't loaded, plus
    /// copy/export.
    var aliasedTranscript: String? {
        guard let transcript, !speakerAliases.isEmpty else { return transcript }
        return Self.applyAliases(transcript, aliases: speakerAliases)
    }

    /// Word-boundary, case-sensitive replacement of each raw label with its
    /// alias. Sorted longest-first so "Speaker 10" wins over "Speaker 1". Only
    /// the exact label string is replaced; lowercase "me" inside sentences
    /// ("Tell me what to do") is preserved because the raw label is "Me".
    private static func applyAliases(_ text: String, aliases: [String: String]) -> String {
        var result = text
        let ordered = aliases.sorted { $0.key.count > $1.key.count }
        for (raw, alias) in ordered where !alias.isEmpty {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: raw))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: alias)
            )
        }
        return result
    }
}

// MARK: - Meeting Kind

enum MeetingKind: String, Codable {
    case meeting       // SCK + mic, two streams, has video
    case voiceNote     // mic-only, audio only
    case imported      // user-imported file

    /// Human-readable noun used in prompt templates (e.g. "voice note", "meeting").
    var noun: String {
        switch self {
        case .meeting: return "meeting"
        case .voiceNote: return "voice note"
        case .imported: return "recording"
        }
    }

    var icon: String {
        switch self {
        case .meeting:   return "video"
        case .voiceNote: return "mic"
        case .imported:  return "doc"
        }
    }
}

// MARK: - Transcript Segment

struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speaker: String
    var text: String

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - Meeting State

enum MeetingState: String, Codable {
    case recording
    case transcribing
    case processing
    case completed
    case failed
}
