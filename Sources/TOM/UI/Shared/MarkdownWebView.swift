import SwiftUI
import WebKit

// MARK: - HTML cache (avoids rebuilding on repeat visits to same meeting)

private final class HTMLCache: @unchecked Sendable {
    static let shared = HTMLCache()
    private var cache: [Int: String] = [:]
    private let lock = NSLock()

    func get(_ key: Int) -> String? { lock.withLock { cache[key] } }
    func set(_ key: Int, _ value: String) { lock.withLock { cache[key] = value } }
}

// MARK: - Markdown Renderer (WKWebView)

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        // Async: WKWebView builds its internal NSScrollView subviews after init
        DispatchQueue.main.async {
            Self.removeScrollbar(in: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isDark = colorScheme == .dark
        let contentHash = markdown.hashValue &* 31 &+ (isDark ? 1 : 0)
        guard contentHash != context.coordinator.lastHash else { return }
        context.coordinator.lastHash = contentHash

        if let cached = HTMLCache.shared.get(contentHash) {
            webView.loadHTMLString(cached, baseURL: nil)
            return
        }

        let markdownCopy = markdown
        Task.detached(priority: .userInitiated) {
            let html = Self.buildHTML(from: markdownCopy, isDark: isDark)
            HTMLCache.shared.set(contentHash, html)
            await MainActor.run(resultType: Void.self) {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    // Recursively finds WKWebView's internal NSScrollView and removes its scrollbar.
    // hasVerticalScroller = false eliminates the reserved gutter space entirely.
    private static func removeScrollbar(in view: NSView) {
        if let sv = view as? NSScrollView {
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
        }
        for subview in view.subviews {
            removeScrollbar(in: subview)
        }
    }

    final class Coordinator: NSObject {
        var lastHash: Int = 0
    }

    // MARK: - HTML Builder (runs off main thread)

    nonisolated static func buildHTML(from markdown: String, isDark: Bool) -> String {
        let textColor  = isDark ? "#e0e0e0" : "#1a1a1a"
        let dimColor   = isDark ? "#999"    : "#666"
        let accentColor = "#f28c26"

        var html = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        html = html.replacingOccurrences(of: "(?m)^### (.+)$", with: "<h3>$1</h3>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^## (.+)$",  with: "<h2>$1</h2>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^# (.+)$",   with: "<h1>$1</h1>", options: .regularExpression)

        html = html.replacingOccurrences(of: "(?m)^- \\[ \\] (.+)$",  with: "<div class='check'><input type='checkbox'><span>$1</span></div>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^- \\[[xX]\\] (.+)$", with: "<div class='check'><input type='checkbox' checked><span class='done'>$1</span></div>", options: .regularExpression)

        html = html.replacingOccurrences(of: "(?m)^  - (.+)$",   with: "<li class='sub'>$1</li>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^    - (.+)$", with: "<li class='sub'>$1</li>", options: .regularExpression)

        html = html.replacingOccurrences(of: "(?m)^- (.+)$", with: "<li>$1</li>", options: .regularExpression)

        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)

        html = html.replacingOccurrences(of: "\n\n", with: "</p><p>")
        html = html.replacingOccurrences(of: "\n", with: "<br>")

        for tag in ["h1", "h2", "h3", "div", "li"] {
            html = html.replacingOccurrences(of: "</\(tag)><br>", with: "</\(tag)>")
            html = html.replacingOccurrences(of: "<br><\(tag)", with: "<\(tag)")
        }

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
            ::-webkit-scrollbar { display: none; }
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px; line-height: 1.7; color: \(textColor);
                padding: 0; -webkit-user-select: text;
            }
            h1 { font-size: 20px; font-weight: 700; margin: 20px 0 8px; }
            h2 { font-size: 17px; font-weight: 700; margin: 18px 0 6px; }
            h3 { font-size: 15px; font-weight: 600; margin: 14px 0 4px; }
            li {
                list-style: disc; margin-left: 20px; padding: 2px 0;
                color: \(textColor);
            }
            li.sub {
                list-style: circle; margin-left: 40px;
                color: \(dimColor); font-size: 13px;
            }
            .check {
                display: flex; align-items: flex-start; gap: 8px;
                padding: 4px 0;
            }
            .check input[type=checkbox] {
                margin-top: 3px; accent-color: \(accentColor);
                width: 16px; height: 16px;
            }
            .check .done { text-decoration: line-through; color: \(dimColor); }
            p { margin: 6px 0; }
            strong { font-weight: 600; }
        </style></head><body>\(html)</body></html>
        """
    }
}
