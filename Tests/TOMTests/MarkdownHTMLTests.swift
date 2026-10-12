import Testing
@testable import TOM

@Suite("Markdown → HTML builder")
struct MarkdownHTMLTests {

    private func html(_ md: String) -> String {
        MarkdownWebView.buildHTML(from: md, isDark: false)
    }

    @Test("Headers render at all three levels")
    func headers() {
        let out = html("# Title\n## Section\n### Sub")
        #expect(out.contains("<h1>Title</h1>"))
        #expect(out.contains("<h2>Section</h2>"))
        #expect(out.contains("<h3>Sub</h3>"))
    }

    @Test("Checkboxes render checked and unchecked")
    func checkboxes() {
        let out = html("- [ ] Open item\n- [x] Done item")
        #expect(out.contains("<input type='checkbox'><span>Open item</span>"))
        #expect(out.contains("<input type='checkbox' checked><span class='done'>Done item</span>"))
    }

    @Test("Bold and list items render")
    func boldAndLists() {
        let out = html("- point one\n**important**")
        #expect(out.contains("<li>point one</li>"))
        #expect(out.contains("<strong>important</strong>"))
    }

    @Test("HTML in the source is escaped, not executed")
    func escapesHTML() {
        let out = html("<script>alert(1)</script> & <b>bold</b>")
        #expect(!out.contains("<script>alert(1)</script>"))
        #expect(out.contains("&lt;script&gt;"))
        #expect(out.contains("&amp;"))
    }

    @Test("Dark and light modes pick different text colors")
    func themeColors() {
        let dark = MarkdownWebView.buildHTML(from: "x", isDark: true)
        let light = MarkdownWebView.buildHTML(from: "x", isDark: false)
        #expect(dark != light)
    }
}
