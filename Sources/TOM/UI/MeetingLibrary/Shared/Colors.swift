import SwiftUI

// MARK: - Color Helpers

extension Color {
    // Backgrounds
    static let sidebarBg   = Color(nsColor: .windowBackgroundColor)
    static let contentBg   = Color(nsColor: .windowBackgroundColor)
    static let panelBg     = Color(nsColor: .windowBackgroundColor)

    // Cards & selection — system semantic colors
    static let cardBg       = Color(nsColor: .controlBackgroundColor)
    static let cardSelected = Color.accent.opacity(0.18)

    // Text — system label colors
    static let subtleText = Color.secondary
    static let dimText    = Color(nsColor: .secondaryLabelColor)

    // Dividers — system separator
    static let divider = Color(nsColor: .separatorColor)

    // Player bar stays dark in both modes (standard for media players)
    static let playerOverlay = Color.black.opacity(0.55)
}
