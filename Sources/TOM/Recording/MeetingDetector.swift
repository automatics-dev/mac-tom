import Foundation
import ScreenCaptureKit

struct DetectedMeeting {
    let sessionID: String
    let bundleID: String
    let displayName: String
    let windowID: CGWindowID
    let windowTitle: String
}

/// Detects when a known meeting application enters an active-call state by
/// matching `SCWindow` titles against per-app signals. Fed by the existing
/// `AppState.refreshWindows` poll — no new timer.
///
/// For browser-hosted meetings (Google Meet, Teams) the title alone is often
/// ambiguous (Firefox renders the active-call title as just "Meet"). We
/// disambiguate by also checking whether the browser process is currently
/// capturing microphone input via the public CoreAudio HAL — the same signal
/// macOS uses to draw the orange recording indicator. No extra permission.
///
/// Session identity is `bundleID + windowID`: a newly-opened meeting window
/// always gets a fresh `CGWindowID`, so closing and starting another meeting
/// in the same app re-fires. A title rename mid-meeting (mute toggle, etc.)
/// keeps the same windowID and is correctly debounced.
@MainActor
final class MeetingDetector {
    struct Signal {
        let bundleIDs: Set<String>
        let displayName: String
        let matches: (_ title: String, _ micActive: Bool) -> Bool
    }

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    private static let signals: [Signal] = [
        Signal(
            bundleIDs: ["us.zoom.xos"],
            displayName: "Zoom",
            matches: { title, _ in title.hasPrefix("Zoom Meeting") }
        ),
        Signal(
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            displayName: "Microsoft Teams",
            matches: { title, _ in
                title.contains("Meeting") || title.contains("| Microsoft Teams")
            }
        ),
        // Browser-hosted meetings: only fire when the browser is actively
        // capturing mic input. "On meet.google.com" alone is a lobby page,
        // not a live call — title-only matching would false-positive.
        Signal(
            bundleIDs: browserBundleIDs,
            displayName: "Google Meet",
            matches: { title, micActive in
                guard micActive else { return false }
                let lower = title.lowercased()
                if lower.contains("google meet") || lower.contains("meet.google.com") {
                    return true
                }
                if title == "Meet" { return true }
                let normalized = title
                    .replacingOccurrences(of: "\u{2013}", with: "-")
                    .replacingOccurrences(of: "\u{2014}", with: "-")
                    .replacingOccurrences(of: "\u{2012}", with: "-")
                return normalized.contains("Meet -")
            }
        ),
        Signal(
            bundleIDs: browserBundleIDs,
            displayName: "Microsoft Teams",
            matches: { title, micActive in
                guard micActive else { return false }
                let lower = title.lowercased()
                return lower.contains("microsoft teams") || lower.contains("teams.microsoft.com")
            }
        ),
        Signal(
            bundleIDs: ["Cisco-Systems.Spark"],
            displayName: "Webex",
            matches: { title, _ in title.contains("Meeting") }
        ),
        Signal(
            bundleIDs: ["com.tinyspeck.slackmacgap"],
            displayName: "Slack Huddle",
            matches: { title, _ in title.contains("Huddle") }
        ),
    ]

    private var seenSessions: Set<String> = []
    private var dismissedSessions: Set<String> = []
    private var loggedDiagnostic: Set<String> = []

    /// Returns meetings detected this poll that have NOT been seen before.
    /// Sessions seen in any earlier poll (including dismissed ones) are filtered
    /// out so the caller never gets a duplicate to re-notify on.
    func evaluate(windows: [SCWindow]) -> [DetectedMeeting] {
        let micPIDs = ProcessAudioMonitor.appsCapturingInput()

        var out: [DetectedMeeting] = []
        for window in windows {
            guard let app = window.owningApplication else { continue }
            let bundleID = app.bundleIdentifier
            guard !bundleID.isEmpty else { continue }
            let title = window.title ?? ""
            guard !title.isEmpty else { continue }
            let micActive = micPIDs.contains(app.processID)

            var matched = false
            for signal in Self.signals {
                guard signal.bundleIDs.contains(bundleID),
                      signal.matches(title, micActive) else { continue }
                matched = true
                let sessionID = "\(bundleID)#\(window.windowID)"
                guard !seenSessions.contains(sessionID),
                      !dismissedSessions.contains(sessionID) else { break }
                seenSessions.insert(sessionID)
                out.append(DetectedMeeting(
                    sessionID: sessionID,
                    bundleID: bundleID,
                    displayName: signal.displayName,
                    windowID: window.windowID,
                    windowTitle: title
                ))
                break
            }

            if !matched,
               Self.browserBundleIDs.contains(bundleID),
               title.lowercased().contains("meet") || title.lowercased().contains("teams") {
                let key = "\(bundleID)#\(app.processID)#\(micActive)#\(title)"
                if !loggedDiagnostic.contains(key) {
                    loggedDiagnostic.insert(key)
                    tomLog("MeetingDetector candidate skipped bundle=\(bundleID) pid=\(app.processID) micActive=\(micActive) title=\(title.debugDescription)")
                }
            }
        }
        return out
    }

    func markDismissed(sessionID: String) {
        dismissedSessions.insert(sessionID)
    }
}
