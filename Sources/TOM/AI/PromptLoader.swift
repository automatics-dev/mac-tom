import Foundation

/// Loads markdown prompt templates from the bundled Resources/Prompts/ directory
/// and renders them by substituting `{{key}}` placeholders.
///
/// Adding a new prompt: drop `<name>.md` into Resources/Prompts/ and reference it
/// here via `PromptLoader.render("<name>", with: [...])`. SPM's `.process` rule
/// flattens subdirectories into the bundle root, so the lookup is by basename only.
///
/// Some prompts (see `userEditablePrompts`) can be overridden by the user via
/// Settings → Advanced. When a non-empty override is stored in `UserDefaults`,
/// it takes precedence over the bundled template.
enum PromptLoader {

    /// Prompts the user can override from Settings → Advanced.
    static let userEditablePrompts: [String] = ["summary-system", "title-system"]

    /// Loads `<name>.md` and substitutes any `{{key}}` placeholders with the
    /// provided values. Trailing whitespace is trimmed so the rendered prompt is
    /// stable regardless of trailing newlines in the file.
    static func render(_ name: String, with variables: [String: String] = [:]) -> String {
        let template = activeTemplate(name)
        var rendered = template
        for (key, value) in variables {
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bundled default prompt as shipped with the app.
    static func defaultTemplate(_ name: String) -> String {
        loadBundledTemplate(name)
    }

    /// User-stored override, or `nil` if the user hasn't customised this prompt.
    static func customTemplate(_ name: String) -> String? {
        guard userEditablePrompts.contains(name) else { return nil }
        let raw = UserDefaults.standard.string(forKey: defaultsKey(for: name)) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Persists or clears a user override. Pass `nil` or an empty/whitespace-only
    /// string to revert to the bundled default.
    static func setCustomTemplate(_ name: String, content: String?) {
        guard userEditablePrompts.contains(name) else { return }
        let key = defaultsKey(for: name)
        let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(content, forKey: key)
        }
    }

    // MARK: - Internal

    /// Returns the user override if one exists, otherwise the bundled template.
    private static func activeTemplate(_ name: String) -> String {
        if let custom = customTemplate(name) { return custom }
        return loadBundledTemplate(name)
    }

    private static func loadBundledTemplate(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else {
            // A missing prompt is a build/packaging bug — fail loudly so it's caught
            // in dev rather than silently sending an empty system prompt to the LLM.
            fatalError("PromptLoader: missing prompt '\(name).md' in bundle. Check Resources/Prompts/ in source and that the asset is in Copy Bundle Resources.")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("PromptLoader: failed to read '\(name).md': \(error)")
        }
    }

    private static func defaultsKey(for name: String) -> String {
        "tom.prompt.\(name)"
    }
}
