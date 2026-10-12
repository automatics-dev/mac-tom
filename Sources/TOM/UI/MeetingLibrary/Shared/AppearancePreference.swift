import AppKit

// MARK: - Appearance Preference

/// Three-state appearance preference. `system` (the default) leaves
/// `NSApp.appearance` nil so the app follows the macOS setting — a user on
/// system-wide dark mode gets a dark TOM without touching anything. Explicit
/// `light`/`dark` pin the app regardless of the OS.
///
/// Persisted under "tom.appearance". The legacy boolean "tom.prefersDark"
/// (two-state, defaulted to light — which forced light mode on dark-mode
/// systems at launch) is migrated on first read: an explicit `true` becomes
/// `.dark`; anything else falls back to `.system` because the old default
/// made "false" indistinguishable from "never chose".
enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    static let storageKey = "tom.appearance"
    private static let legacyKey = "tom.prefersDark"

    static var current: AppearancePreference {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: storageKey),
           let pref = AppearancePreference(rawValue: raw) {
            return pref
        }
        if defaults.object(forKey: legacyKey) != nil, defaults.bool(forKey: legacyKey) {
            return .dark
        }
        return .system
    }

    static func set(_ pref: AppearancePreference) {
        UserDefaults.standard.set(pref.rawValue, forKey: storageKey)
        pref.apply()
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var next: AppearancePreference {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }

    var label: String {
        switch self {
        case .system: "Appearance: System"
        case .light: "Appearance: Light"
        case .dark: "Appearance: Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
