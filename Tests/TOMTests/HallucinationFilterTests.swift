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
