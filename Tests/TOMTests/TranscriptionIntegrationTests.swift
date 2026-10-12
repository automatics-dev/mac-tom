import AVFoundation
import Foundation
import Testing
@testable import TOM

/// Real-model integration tests. Opt-in: they need the AI models on disk and
/// take seconds-to-minutes, so they only run when TOM_INTEGRATION_TESTS=1 is
/// set in the environment (never on CI).
///
///     TOM_INTEGRATION_TESTS=1 xcodebuild test -project TOM.xcodeproj -scheme TOM
@Suite(
    "Transcription integration (real models)",
    .enabled(if: ProcessInfo.processInfo.environment["TOM_INTEGRATION_TESTS"] == "1")
)
struct TranscriptionIntegrationTests {

    /// Synthesises a WAV that speaks nothing (tone + silence). The assertion
    /// is structural — the engines must return without throwing and must not
    /// hallucinate text out of a speech-free file.
    private func makeToneWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tom-test-\(UUID().uuidString).wav")
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = Float(0.05 * sin(2.0 * .pi * 440.0 * Double(i) / rate))
        }
        try file.write(from: buffer)
        return url
    }

    @Test("Parakeet transcribes a speech-free file without hallucinating",
          .enabled(if: ParakeetTranscriber.isModelReady))
    func parakeetOnTone() async throws {
        let url = try makeToneWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await ParakeetTranscriber.shared.transcribe(fileURL: url, onSegmentDiscovered: nil)
        // A pure tone must not produce hallucinated phrases.
        for seg in outcome.segments {
            #expect(!WhisperKitTranscriber.isHallucination(seg.text))
        }
    }

    @Test("Whisper transcribes a speech-free file without hallucinating",
          .enabled(if: WhisperKitTranscriber.isModelReady))
    func whisperOnTone() async throws {
        let url = try makeToneWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await WhisperKitTranscriber.shared.transcribe(fileURL: url, onSegmentDiscovered: nil)
        for seg in outcome.segments {
            #expect(!WhisperKitTranscriber.isHallucination(seg.text))
        }
    }
}
