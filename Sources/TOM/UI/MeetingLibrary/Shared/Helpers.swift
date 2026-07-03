import SwiftUI

// MARK: - Duration Formatter

func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    guard total > 0 else { return "0s" }
    let hours = total / 3600; let minutes = (total % 3600) / 60; let seconds = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
}

func formatTimestamp(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - Icon Helpers

/// Returns the icon string for display. Falls back to "📁" if stored value looks like an
/// SF Symbol name (SF Symbol names always contain a dot, e.g. "folder.fill", "tray.fill").
/// This handles existing groups created before the emoji migration (D-06, Risk 4 from RESEARCH.md).
func displayIcon(_ icon: String) -> String {
    icon.contains(".") ? "📁" : icon
}

// MARK: - Date Formatters

let shortDateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
}()
