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

    // MARK: - 页内查找（阅读页放大镜）

    func testFindScriptPresentInWrappedHTML() {
        let html = NoteHTML.wrap(title: "t", raw: "<p>x</p>", noteType: "text")
        XCTAssertTrue(html.contains("window.__triliumFind"), "查找脚本必须随增强脚本注入")
        XCTAssertTrue(html.contains("tf-hit"), "命中高亮样式必须存在")
        XCTAssertTrue(html.contains("tf-cur"), "当前命中样式必须存在")
    }

    func testJSLiteralEscapesSpecials() {
        // 关键词含引号/反斜杠/换行时必须是合法 JS 字符串字面量
        XCTAssertEqual(ContentWebView.Coordinator.jsLiteral(#"a"b\c"# + "\nd"), "\"a\\\"b\\\\c\\nd\"")
        XCTAssertEqual(ContentWebView.Coordinator.jsLiteral(""), "\"\"")
    }

    func testIntPairParsing() {
        XCTAssertEqual(ContentWebView.Coordinator.intPair([1, 12] as [Any]).1, 12)
        XCTAssertEqual(ContentWebView.Coordinator.intPair([NSNumber(value: 3), NSNumber(value: 7)]).0, 3)
        // 非数组 / 长度不足 → 0/0，别崩
        XCTAssertEqual(ContentWebView.Coordinator.intPair("x").0, 0)
        XCTAssertEqual(ContentWebView.Coordinator.intPair(nil).1, 0)
        XCTAssertEqual(ContentWebView.Coordinator.intPair([NSNumber(value: 1)]).1, 0)
    }

    func testIntValueParsing() {
        XCTAssertEqual(ContentWebView.Coordinator.intValue(NSNumber(value: 5)), 5)
        XCTAssertEqual(ContentWebView.Coordinator.intValue(nil), 0)
        XCTAssertEqual(ContentWebView.Coordinator.intValue("x"), 0)
    }

    // MARK: - NoteCache 版本戳（打开过的笔记不重复云加载，改过才同步）

    func testStampSaveAndOverwrite() {
        NoteCache.shared.saveStamp("test-stamp-1", stamp: "v1")
        XCTAssertEqual(NoteCache.shared.cachedStamp("test-stamp-1"), "v1")
        NoteCache.shared.saveStamp("test-stamp-1", stamp: "v2")
        XCTAssertEqual(NoteCache.shared.cachedStamp("test-stamp-1"), "v2")
    }

    func testStampEmptyIsIgnored() {
        // 空戳（服务端没返回 utcDateModified）不能覆盖已有记录，也不能新增
        NoteCache.shared.saveStamp("test-stamp-2", stamp: "")
        XCTAssertNil(NoteCache.shared.cachedStamp("test-stamp-2"))
        NoteCache.shared.saveStamp("test-stamp-2", stamp: nil)
        XCTAssertNil(NoteCache.shared.cachedStamp("test-stamp-2"))
    }

    func testSaveContentRecordsStamp() {
        NoteCache.shared.saveContent("test-stamp-3", text: "x", stamp: "s1")
        XCTAssertEqual(NoteCache.shared.cachedStamp("test-stamp-3"), "s1")
        // 编辑器本地保存（不传戳）不能动已记录的版本戳：
        // 服务端已改成新戳，保持旧戳才能让下次打开发现不一致并重拉
        NoteCache.shared.saveContent("test-stamp-3", text: "y")
        XCTAssertEqual(NoteCache.shared.cachedStamp("test-stamp-3"), "s1")
    }

    func testRemoveClearsStamp() {
        NoteCache.shared.saveStamp("test-stamp-4", stamp: "v")
        NoteCache.shared.remove("test-stamp-4")
        XCTAssertNil(NoteCache.shared.cachedStamp("test-stamp-4"))
    }

    // MARK: - 富文本编辑：整篇 HTML → 可编辑片段

    func testEditableBodyStripsFullDocument() {
        let html = "<!DOCTYPE html><html><head><title>x</title></head><body><p>hi</p></body></html>"
        XCTAssertEqual(RichTextEditorView.editableBody(from: html), "<p>hi</p>")
    }

    func testEditableBodyKeepsFragment() {
        XCTAssertEqual(RichTextEditorView.editableBody(from: "<p>a</p>"), "<p>a</p>")
    }

    // MARK: - 富文本编辑页（脚本必须闭合、桥接名要对）

    func testRichEditorPageStructure() {
        let html = RichTextEditorView.pageHTML(body: "<p>x</p>", fontScale: 1.0)
        let opens = html.components(separatedBy: "<script").count - 1
        let closes = html.components(separatedBy: "</script>").count - 1
        XCTAssertEqual(opens, closes)
        XCTAssertTrue(html.contains("contenteditable=\"true\""))
        XCTAssertTrue(html.contains("messageHandlers.state"))
        XCTAssertTrue(html.contains("messageHandlers.dirty"))
        XCTAssertTrue(html.contains("__getHTML"))
        XCTAssertTrue(html.contains("__insertLink"))
    }
}
