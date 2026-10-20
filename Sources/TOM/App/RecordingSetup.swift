import CoreGraphics
import Foundation

/// The record panel's choices, remembered between recordings so the panel
/// opens on the last setup.
struct RecordingSetup: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case meeting, voiceNote, feedback
    }

    enum Source: String, Codable {
        case window, screen
    }

    var mode: Mode = .meeting
    var source: Source = .window
    /// Last recorded window, matched by app and title on the next start
    /// (window IDs don't survive relaunches).
    var windowBundleID: String?
    var windowAppName: String?
    var windowTitle: String?
    var displayID: CGDirectDisplayID?
    var microphone = true
    var meetingSystemAudio = true
    /// Feedback sessions record the narration; a site's own sound is opt-in.
    var feedbackSystemAudio = false

    var systemAudio: Bool {
        get { mode == .feedback ? feedbackSystemAudio : meetingSystemAudio }
        set {
            if mode == .feedback { feedbackSystemAudio = newValue } else { meetingSystemAudio = newValue }
        }
    }

    /// Screen recordings need at least one audio source to transcribe;
    /// voice notes always use the mic.
    var hasAudio: Bool { mode == .voiceNote || microphone || systemAudio }

    var captureOptions: CaptureOptions {
        CaptureOptions(systemAudio: systemAudio, microphone: microphone)
    }

    // MARK: - Persistence

    private static let key = "tom.recordingSetup"

    static func load() -> RecordingSetup {
        guard let data = UserDefaults.standard.data(forKey: key),
              let setup = try? JSONDecoder().decode(RecordingSetup.self, from: data) else { return RecordingSetup() }
        return setup
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
