import AVFoundation
import Foundation
import Testing
@testable import TOM

// MARK: - Known no-speech artifacts (the "Thank you." family)

@Suite("Known no-speech artifact filter")
struct KnownNoSpeechArtifactTests {

    @Test("Single blacklisted phrases are caught", arguments: [
        "Thank you.",
        "Thank you very much.",
        "Thanks for watching!",
        "Subscribe to my channel",
        "Vielen Dank",
        "Untertitelung des ZDF",
        "Gracias por ver",
        "Merci beaucoup",
        "Grazie mille",
        "Sottotitoli creati dalla comunità Amara.org",
    ])
    func catchesSinglePhrases(_ text: String) {
        #expect(WhisperKitTranscriber.isKnownNoSpeechArtifact(text))
    }

    @Test("Back-to-back repeats under the 40-char floor are caught")
    func catchesShortRepeats() {
        #expect(WhisperKitTranscriber.isKnownNoSpeechArtifact("Thank you. Thank you. Thank you."))
        #expect(WhisperKitTranscriber.isKnownNoSpeechArtifact("Gracias. Gracias."))
    }

    @Test("Real speech containing a blacklisted phrase survives", arguments: [
        "Thank you for the update, let's move to the budget.",
        "I just wanted to say thanks for watching the demo yesterday and share feedback.",
        "Vielen Dank, dann machen wir mit dem nächsten Punkt weiter.",
        "Okay great.",
        "Yeah yeah yeah",
    ])
    func keepsRealSpeech(_ text: String) {
        #expect(!WhisperKitTranscriber.isKnownNoSpeechArtifact(text))
    }

    @Test("Empty and whitespace-only input is not an artifact")
    func emptyInput() {
        #expect(!WhisperKitTranscriber.isKnownNoSpeechArtifact(""))
        #expect(!WhisperKitTranscriber.isKnownNoSpeechArtifact("   \n"))
    }
}

// MARK: - Repetition-based hallucinations

@Suite("Repetitive hallucination filter")
struct RepetitiveHallucinationTests {

    @Test("Classic YouTube-outro loops are caught")
    func catchesLoops() {
        let loop = String(repeating: "Subscribe to my channel. ", count: 6)
        #expect(WhisperKitTranscriber.isRepetitiveHallucination(loop))

        let thanks = String(repeating: "Thank you. ", count: 10)
        #expect(WhisperKitTranscriber.isRepetitiveHallucination(thanks))
    }

    @Test("Legitimate short utterances survive the 40-char floor")
    func keepsShortUtterances() {
        #expect(!WhisperKitTranscriber.isRepetitiveHallucination("Yeah yeah yeah"))
        #expect(!WhisperKitTranscriber.isRepetitiveHallucination("No. No. No."))
    }

    @Test("Normal varied speech is never flagged")
    func keepsVariedSpeech() {
        let speech = "We agreed on the Q3 roadmap, Maria takes the migration, and the design review moves to Thursday because of the offsite."
        #expect(!WhisperKitTranscriber.isRepetitiveHallucination(speech))
    }

    @Test("Umbrella check combines both filters")
    func umbrellaCheck() {
        #expect(WhisperKitTranscriber.isHallucination("Thank you."))
        #expect(WhisperKitTranscriber.isHallucination(String(repeating: "Thank you. ", count: 10)))
        #expect(!WhisperKitTranscriber.isHallucination("Thank you for joining, agenda is on screen."))
    }
}

// MARK: - Whisper control-token cleanup

@Suite("Whisper text cleanup")
struct CleanWhisperTextTests {

    @Test("Control tokens and timestamps are stripped")
    func stripsTokens() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello there<|2.40|><|endoftext|>"
        #expect(WhisperKitTranscriber.cleanWhisperText(raw) == "Hello there")
    }

    @Test("Whitespace runs collapse to single spaces")
    func collapsesWhitespace() {
        #expect(WhisperKitTranscriber.cleanWhisperText("a  <|0.00|>  b") == "a b")
    }

    @Test("Plain text passes through unchanged")
    func passthrough() {
        #expect(WhisperKitTranscriber.cleanWhisperText("Plain sentence.") == "Plain sentence.")
    }
}

@Suite("Meeting title")
struct MeetingTitleTests {

    @Test("AI title replaces a non-custom title")
    func aiTitleApplies() {
        var m = Meeting(title: "Recording — Chrome")
        m.applyAITitle("Weekly sync")
        #expect(m.title == "Weekly sync")
    }

    @Test("AI title never replaces a user-set title")
    func aiTitleSkipsCustom() {
        var m = Meeting(title: "Old")
        m.rename(to: "Client kickoff")
        m.applyAITitle("Weekly sync")
        #expect(m.title == "Client kickoff")
        #expect(m.titleIsCustom)
    }

    @Test("Empty AI title keeps the current one")
    func emptyAITitleIgnored() {
        var m = Meeting(title: "Recording — Chrome")
        m.applyAITitle("")
        #expect(m.title == "Recording — Chrome")
    }

    @Test("Rename trims; empty rename releases the title back to AI")
    func renameRules() {
        var m = Meeting(title: "Old")
        m.rename(to: "  Board review  ")
        #expect(m.title == "Board review")
        #expect(m.titleIsCustom)
        m.rename(to: "   ")
        #expect(m.title == "Board review")
        #expect(!m.titleIsCustom)
    }

    @Test("Custom title survives the save/fetch round trip")
    func persistsFlag() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = StorageManager(home: home)
        var m = try storage.createMeeting(title: "Old")
        #expect(try storage.fetchMeeting(id: m.id)?.titleIsCustom == false)
        m.rename(to: "Client kickoff")
        try storage.updateMeeting(m)
        let fetched = try storage.fetchMeeting(id: m.id)
        #expect(fetched?.title == "Client kickoff")
        #expect(fetched?.titleIsCustom == true)
    }
}

@Suite("Meeting media export")
struct MeetingMediaExportTests {
    @Test func fileNameReplacesPathSeparators() {
        let meeting = Meeting(title: "Q3/Q4 review: plan")
        let name = meeting.exportFileName(ext: "mp4")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasPrefix("Q3-Q4 review- plan-"))
        #expect(name.hasSuffix(".mp4"))
    }

    @Test func audioExportMixesPendingMic() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tom-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recording = dir.appendingPathComponent("rec.m4a")
        let mic = dir.appendingPathComponent("rec.mic.wav")
        try Self.writeTone(to: recording, seconds: 1, aac: true)
        try Self.writeTone(to: mic, seconds: 1, aac: false)

        let output = dir.appendingPathComponent("out.m4a")
        try await AudioMuxer.exportMeetingMedia(recording: recording, mic: mic, kind: .audio, to: output)

        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1) < 0.2)
        // The stored recording is never modified by an export.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("rec.mic-muxed").path))
    }

    @Test func audioExportCopiesM4AWithoutMic() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tom-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recording = dir.appendingPathComponent("note.m4a")
        try Self.writeTone(to: recording, seconds: 1, aac: true)
        let output = dir.appendingPathComponent("out.m4a")
        try await AudioMuxer.exportMeetingMedia(recording: recording, mic: nil, kind: .audio, to: output)

        #expect(FileManager.default.contentsEqual(atPath: recording.path, andPath: output.path))
    }

    private static func writeTone(to url: URL, seconds: Double, aac: Bool) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 48_000)
        }
        try file.write(from: buffer)
    }
}
