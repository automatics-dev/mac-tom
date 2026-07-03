import Combine
import Foundation

/// Serialises post-recording AI work (Whisper transcription → Qwen summary →
/// MLX embeddings) so concurrent retranscribes or imports can't peg the CPU,
/// blow up unified memory, or contend on the WhisperKit / MLX actors.
///
/// One job runs at a time; everything else waits in FIFO order. Retranscribes,
/// imports, live-recording stop, and voice-note stop all enqueue here, so a
/// "retranscribe these 4 meetings" gesture or a multi-file Import Open Panel
/// processes one at a time instead of forking 4–5 inference pipelines that
/// fight over the GPU and ~3 GB of resident model RAM.
///
/// Per-meeting visibility: SwiftUI views observe `queuedMeetingIds` to render
/// a "Queued" badge in the meeting list while a job waits its turn. Once the
/// worker picks the job up, `queuedMeetingIds` removes the id and the existing
/// `MeetingState` (`.transcribing`, `.processing`, `.completed`) drives the
/// rest of the badge logic.
///
/// Lives on the main actor so `@Published` updates fire on the UI thread.
/// State is in-memory only — a crash mid-queue drops pending closures (the
/// underlying recording files persist on disk; the user can re-trigger).
@MainActor
final class ProcessingQueue: ObservableObject {

    static let shared = ProcessingQueue()

    /// IDs of meetings whose work is queued but not yet started. Drives the
    /// "Queued" badge.
    @Published private(set) var queuedMeetingIds: Set<UUID> = []

    private var pending: [(UUID, @Sendable () async -> Void)] = []
    private var draining = false

    private init() {}

    /// Append a job for `meetingId`. The meeting shows up as "Queued" until
    /// its turn comes; then `work` runs (off this actor) and the queue badge
    /// clears.
    func enqueue(meetingId: UUID, work: @escaping @Sendable () async -> Void) {
        pending.append((meetingId, work))
        queuedMeetingIds.insert(meetingId)
        tomLog("Queue: enqueue meeting \(meetingId.uuidString.prefix(8)) — \(pending.count) pending")
        if !draining { Task { await self.drain() } }
    }

    /// True when this meeting is queued but not yet being processed.
    func isQueued(_ id: UUID) -> Bool {
        queuedMeetingIds.contains(id)
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        tomLog("Queue: draining started (\(pending.count) pending)")
        defer {
            draining = false
            tomLog("Queue: drained, idle")
        }
        while !pending.isEmpty {
            let (id, work) = pending.removeFirst()
            queuedMeetingIds.remove(id)
            tomLog("Queue: processing meeting \(id.uuidString.prefix(8)) (\(pending.count) remaining)")
            let started = Date()
            await work()
            tomLog("Queue: meeting \(id.uuidString.prefix(8)) finished in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
    }
}
