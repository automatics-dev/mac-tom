import Foundation

/// Dev-mode flag, opt-in via the `TOM_DEV_MODE` environment variable.
/// Enable by launching with `TOM_DEV_MODE=1 swift run TOM` (or set it in Xcode's
/// scheme env vars). Resolved once at process start.
enum DevMode {
    static let isEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["TOM_DEV_MODE"] else { return false }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }()
}
