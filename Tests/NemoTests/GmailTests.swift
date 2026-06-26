import XCTest
@testable import Nemo

final class GmailTests: XCTestCase {

    func testMessageRendersAsImportContext() {
        let m = GmailService.Message(
            id: "1", from: "Alex <alex@acme.com>", to: "me@x.com",
            subject: "Q3 planning", date: "Mon, 1 Jun 2026 09:00:00 +0000",
            snippet: "let's lock the roadmap", body: "We agreed to ship the beta by July 10.")
        let ctx = m.asContext
        XCTAssertTrue(ctx.hasPrefix("### Email: Q3 planning"))
        XCTAssertTrue(ctx.contains("From: Alex <alex@acme.com>"))
        XCTAssertTrue(ctx.contains("To: me@x.com"))
        XCTAssertTrue(ctx.contains("ship the beta by July 10"))
    }

    func testMessageFallsBackToSnippetWhenNoBody() {
        let m = GmailService.Message(id: "2", from: "", to: "", subject: "",
                                     date: "", snippet: "just a snippet", body: "")
        let ctx = m.asContext
        XCTAssertTrue(ctx.contains("### Email: (no subject)"))
        XCTAssertTrue(ctx.contains("just a snippet"))
    }

    func testExtractsPlainTextPartPreferredOverHTML() {
        // base64url("Plain body line") and an HTML alternative.
        let plain = "UGxhaW4gYm9keSBsaW5l"           // "Plain body line"
        let payload: [String: Any] = [
            "mimeType": "multipart/alternative",
            "parts": [
                ["mimeType": "text/html", "body": ["data": "PGI-aWdub3JlPC9iPg"]],
                ["mimeType": "text/plain", "body": ["data": plain]]
            ]
        ]
        XCTAssertEqual(GmailService._testExtractBody(payload), "Plain body line")
    }

    func testStripsHTMLToReadableText() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;<b>world</b></p><script>evil()</script></body></html>"
        let text = GmailService._testStripHTML(html)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertFalse(text.contains("evil"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertFalse(text.contains("<"))
    }
}
