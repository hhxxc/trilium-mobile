import XCTest
@testable import TriliumMobile

/// 纯函数单元测试：这些函数不碰网络/UI，是最值得测、也最容易回归的部分。
final class PureFunctionTests: XCTestCase {

    // MARK: - NoteRow.plainText（HTML → 纯文本）

    func testPlainTextStripsTags() {
        XCTAssertEqual(NoteRow.plainText(from: "<p>hello <b>world</b></p>"), "hello world")
    }

    func testPlainTextDecodesEntities() {
        XCTAssertEqual(NoteRow.plainText(from: "a &amp; b &lt; c"), "a & b < c")
    }

    func testPlainTextEmpty() {
        XCTAssertEqual(NoteRow.plainText(from: "   "), "")
    }

    // MARK: - ComposeView.html（纯文本 → 段落 HTML）

    func testHTMLSingleParagraph() {
        XCTAssertEqual(ComposeView.html(fromPlain: "hello"), "<p>hello</p>")
    }

    func testHTMLMultiParagraph() {
        XCTAssertEqual(ComposeView.html(fromPlain: "a\n\nb"), "<p>a</p><p>b</p>")
    }

    func testHTMLEscapesSpecialChars() {
        XCTAssertEqual(ComposeView.html(fromPlain: "a < b & c"), "<p>a &lt; b &amp; c</p>")
    }

    func testHTMLBlankInput() {
        XCTAssertEqual(ComposeView.html(fromPlain: "  \n\n  "), "")
    }

    // MARK: - NoteDetailView.fileExtension / sniffExtension（附件扩展名判定）

    func testFileExtensionFromMime() {
        XCTAssertEqual(NoteDetailView.fileExtension(mime: "application/pdf", name: "doc"), "pdf")
    }

    func testFileExtensionFromName() {
        XCTAssertEqual(NoteDetailView.fileExtension(mime: nil, name: "report.pdf"), "pdf")
    }

    func testFileExtensionUnknown() {
        XCTAssertEqual(NoteDetailView.fileExtension(mime: nil, name: "noext"), "")
    }

    func testSniffPDF() {
        XCTAssertEqual(NoteDetailView.sniffExtension(Data([0x25, 0x50, 0x44, 0x46])), "pdf")
    }

    func testSniffZIP() {
        XCTAssertEqual(NoteDetailView.sniffExtension(Data([0x50, 0x4B, 0x03, 0x04])), "zip")
    }

    func testSniffPNG() {
        XCTAssertEqual(NoteDetailView.sniffExtension(Data([0x89, 0x50, 0x4E, 0x47])), "png")
    }

    func testSniffUnknown() {
        XCTAssertNil(NoteDetailView.sniffExtension(Data([0x00, 0x01, 0x02])))
    }

    // MARK: - PendingOp 向后兼容（老版本队列缺 noteType/baseStamp/conflicted）

    func testPendingOpDecodesLegacyJSON() throws {
        let json = """
        [{"kind":"putContent","id":"1","noteId":"abc","title":"t","content":"c","createdAt":0}]
        """.data(using: .utf8)!
        let ops = try JSONDecoder().decode([PendingOp].self, from: json)
        XCTAssertEqual(ops.count, 1)
        XCTAssertNil(ops[0].noteType)      // 老队列没有这个键，必须是 nil 而不是抛错
        XCTAssertFalse(ops[0].conflicted)
    }

    func testPendingOpRoundTripsCreateWithBody() throws {
        let op = PendingOp(kind: "create", id: "2", noteId: "", title: "标题",
                           content: "<p>正文</p>", noteType: "text", parentNoteId: "inbox")
        let data = try JSONEncoder().encode(op)
        let back = try JSONDecoder().decode(PendingOp.self, from: data)
        XCTAssertEqual(back.content, "<p>正文</p>")
        XCTAssertEqual(back.noteType, "text")
        XCTAssertEqual(back.parentNoteId, "inbox")
    }

    // MARK: - 阅读页 HTML 增强脚本（2026-10-22 前 <script> 未闭合，整段 JS 语法错误）

    func testWrappedHTMLHasBalancedScriptTags() {
        let html = NoteHTML.wrap(title: "t", raw: "<p>x</p>", noteType: "text")
        let opens = html.components(separatedBy: "<script").count - 1
        let closes = html.components(separatedBy: "</script>").count - 1
        XCTAssertEqual(opens, closes, "增强脚本里 <script> 与 </script> 必须成对，否则整段不执行")
    }

    // MARK: - 富文本编辑：整篇 HTML → 可编辑片段

    func testEditableBodyStripsFullDocument() {
        let html = "<!DOCTYPE html><html><head><title>x</title></head><body><p>hi</p></body></html>"
        XCTAssertEqual(RichTextEditorView.editableBody(from: html), "<p>hi</p>")
    }

    func testEditableBodyKeepsFragment() {
        XCTAssertEqual(RichTextEditorView.editableBody(from: "<p>a</p>"), "<p>a</p>")
    }
}
