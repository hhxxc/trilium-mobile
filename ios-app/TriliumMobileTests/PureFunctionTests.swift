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
}
