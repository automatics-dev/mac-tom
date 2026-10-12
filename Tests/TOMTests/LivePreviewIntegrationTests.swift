import AVFoundation
import Foundation
import Testing
@testable import TOM

/// Streams a speech file through `StreamingTranscriptionSession` at real-time
/// pace and checks that the Parakeet rolling preview shows words long before
/// the first 5 s chunk commits. Opt-in like the other real-model tests:
///
///     TOM_INTEGRATION_TESTS=1 TOM_TEST_SPEECH_FILE=/path/speech.wav \
///         xcodebuild test -project TOM.xcodeproj -scheme TOM
@Suite(
    "Live preview integration (real Parakeet model)",
    .enabled(if: ProcessInfo.processInfo.environment["TOM_INTEGRATION_TESTS"] == "1"
        && ProcessInfo.processInfo.environment["TOM_TEST_SPEECH_FILE"] != nil)
)
struct LivePreviewIntegrationTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [(seconds: Double, update: StreamingTranscriptionSession.LiveUpdate)] = []
        private let start = Date()
        func record(_ update: StreamingTranscriptionSession.LiveUpdate) {
            lock.withLock { events.append((Date().timeIntervalSince(start), update)) }
        }
        var snapshot: [(seconds: Double, update: StreamingTranscriptionSession.LiveUpdate)] {
            lock.withLock { events }
        }
    }

    @Test("Preview words arrive within ~2 s of speech", .enabled(if: TranscriptionEngine.selected == .parakeet))
    func previewLatency() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOM_TEST_SPEECH_FILE"]!)
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let converter = try #require(StreamingFormatConverter(from: file.processingFormat))
        let samples = converter.convert(buffer)

        await ParakeetTranscriber.shared.preload()
        let recorder = Recorder()
        let session = StreamingTranscriptionSession(sources: ["system": "Speaker"], primary: "system") {
            recorder.record($0)
        }

        // Feed 100 ms buffers at real-time pace.
        let step = StreamingTranscriptionSession.sampleRate / 10
        var index = 0
        while index < samples.count {
            let end = min(index + step, samples.count)
            await session.append(Array(samples[index..<end]), source: "system")
            index = end
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let outcome = await session.finish()
        try await Task.sleep(nanoseconds: 200_000_000)

        let events = recorder.snapshot
        // Timeline for eyeballing latency: $TMPDIR/tom-live-preview-timeline.txt
        let timeline = events.map {
            String(format: "[%5.2fs] committed=%@ preview=%@", $0.seconds,
                   $0.update.committed.description, $0.update.preview ?? "nil")
        }.joined(separator: "\n")
        try? timeline.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("tom-live-preview-timeline.txt"),
            atomically: true, encoding: .utf8)
        let firstPreview = events.first { !($0.update.preview ?? "").isEmpty }
        let firstCommit = events.first { !$0.update.committed.isEmpty }
        let previewCount = events.filter { !($0.update.preview ?? "").isEmpty }.count

        #expect(outcome != nil)
        #expect(previewCount >= 10)
        // Speech starts at 0 s; with a 1 s minimum tail the first preview should land by ~2 s.
        #expect((firstPreview?.seconds ?? .infinity) < 2.5)
        #expect((firstPreview?.seconds ?? .infinity) < (firstCommit?.seconds ?? .infinity))
    }
}
