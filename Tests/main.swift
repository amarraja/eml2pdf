// Minimal test runner (the Command Line Tools ship without XCTest).
// Usage: run-tests <fixtures-dir>
import AppKit
import PDFKit

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL \((file as NSString).lastPathComponent):\(line): \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures")
func fixture(_ name: String) throws -> EmailMessage {
    try MIMEParser.parse(contentsOf: fixtures.appendingPathComponent(name))
}

func eml(_ text: String) -> EmailMessage {
    MIMEParser.parse(data: Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
}

// MARK: Decoding

test("RFC 2047 encoded-words") {
    expect(HeaderDecoding.decodeWords("=?utf-8?q?Zo=C3=AB?= Alvarez") == "Zoë Alvarez", "Q-encoding")
    expect(HeaderDecoding.decodeWords("=?UTF-8?B?w4l0w6k=?=") == "Été", "B-encoding")
    expect(HeaderDecoding.decodeWords("=?iso-8859-1?q?caf=E9?= =?iso-8859-1?q?_cr=E8me?=") == "café crème",
           "adjacent words join without whitespace, underscore is space")
    expect(HeaderDecoding.decodeWords("plain subject") == "plain subject", "plain text untouched")
}

test("quoted-printable and base64") {
    let qp = Decoding.quotedPrintable(Data("caf=C3=A9 soft=\nbreak =3D ok".utf8))
    expect(String(decoding: qp, as: UTF8.self) == "café softbreak = ok", "QP decode")
    let b64 = Decoding.base64(Data("aGVs\nbG8g\nd29y bGQ".utf8))
    expect(String(decoding: b64, as: UTF8.self) == "hello world", "base64 with whitespace and no padding")
}

test("RFC 2231 parameters") {
    let v = HeaderDecoding.parseHeaderValue("attachment; filename*0*=utf-8''%C3%9Cber; filename*1*=%20Plan.pdf")
    expect(v.value == "attachment", "value")
    expect(v.params["filename"] == "Über Plan.pdf", "continuations joined: \(v.params["filename"] ?? "nil")")
    let q = HeaderDecoding.parseHeaderValue(#"text/plain; charset="ISO-8859-1"; name="a;b.txt""#)
    expect(q.params["charset"] == "ISO-8859-1" && q.params["name"] == "a;b.txt", "quoted params with separators")
}

test("address lists") {
    let list = HeaderDecoding.parseAddressList(#""Smith, Bob" <bob@x.com>, carol@y.org, =?utf-8?q?Dana_=C3=98?= <d@z.net>, e@w.com (Eve)"#)
    expect(list.count == 4, "four addresses, got \(list.count)")
    expect(list.first?.name == "Smith, Bob" && list.first?.email == "bob@x.com", "quoted comma in name")
    expect(list[2].display == "Dana Ø <d@z.net>", "encoded display name")
    expect(list[3].name == "Eve" && list[3].email == "e@w.com", "comment-style name")
    expect(HeaderDecoding.parseAddressList("undisclosed-recipients:;").isEmpty, "empty group")
}

// MARK: Message structure

test("rich fixture: headers, alternative + related, attachments") {
    let m = try fixture("rich.eml")
    expect(m.subject == "Q3 roadmap — résumé & next steps ✅", "subject: \(m.subject)")
    expect(m.from.first?.display == "Zoë Alvarez <zoe@example.com>", "from")
    expect(m.to.map(\.email) == ["bob@example.com", "carol@example.org"], "to")
    expect(m.cc.first?.name == "Dana Øberg", "cc")
    expect(m.bcc.map(\.email) == ["secret-archive@example.com"], "bcc")
    expect(m.replyTo.first?.email == "roadmap@example.com", "reply-to")
    expect(m.date != nil, "date parsed")
    expect(m.body.count == 1, "alternative picks one body")
    if case let .html(html)? = m.body.first { expect(html.contains("cid:logo@example.com"), "html body chosen") }
    else { expect(false, "html body chosen") }
    let names = m.attachments.map(\.displayName)
    expect(names == ["logo.png", "Ünïcode photo.png", "Q3 Roadmap.pdf", "archive.zip"], "attachments: \(names)")
    expect(m.contentIDMap["logo@example.com"] != nil, "cid map")
}

test("latin-1 quoted-printable text body") {
    let m = try fixture("reply.eml")
    guard case let .text(text)? = m.body.first else { return expect(false, "text body") }
    expect(text.contains("ça marche") && text.contains("Café"), "decoded iso-8859-1: \(text)")
}

test("message/rfc822 attachment is parsed") {
    let m = try fixture("forward.eml")
    expect(m.embeddedMessages.count == 1, "one embedded message")
    expect(m.embeddedMessages.first?.subject == "Original vendor quote", "embedded subject")
    expect(m.embeddedMessages.first?.attachments.first?.filename == "quote-4471.pdf", "embedded attachment")
    expect(m.attachments.first?.displayName == "Original vendor quote.eml", "listed as attachment")
}

test("text-only email without MIME headers") {
    let m = eml("From: a@b.com\nTo: c@d.com\nSubject: hi\n\nJust text.\n")
    expect(m.subject == "hi", "subject")
    if case let .text(t)? = m.body.first { expect(t.contains("Just text."), "body") } else { expect(false, "text body") }
    expect(m.attachments.isEmpty, "no attachments")
}

test("mixed body parts keep order, inline images without cid become attachments") {
    let m = eml("""
    From: a@b.com
    Subject: mixed
    Content-Type: multipart/mixed; boundary=XX

    preamble
    --XX
    Content-Type: text/plain

    first
    --XX
    Content-Type: image/jpeg; name=photo.jpg
    Content-Disposition: inline
    Content-Transfer-Encoding: base64

    /9j/4AAQ
    --XX
    Content-Type: text/plain

    second
    --XX--
    epilogue
    """)
    expect(m.body.count == 2, "two text segments, got \(m.body.count)")
    expect(m.attachments.map(\.displayName) == ["photo.jpg"], "photo is an attachment")
}

// MARK: HTML

test("HTML: sanitising, cid rewrite, scoping, gallery") {
    let html = HTMLBuilder().build(messages: [try fixture("rich.eml")])
    expect(!html.contains("<script"), "scripts removed")
    expect(!html.contains("onload"), "event handlers removed")
    expect(!html.contains("javascript:"), "javascript: links removed")
    expect(!html.contains("cid:logo"), "cid rewritten")
    expect(html.contains("data:image/png;base64,"), "data URI present")
    expect(html.contains(".email-content.m1 {"), "body selector scoped")
    expect(html.contains("secret-archive@example.com"), "bcc shown")
    expect(html.contains("e2p-gallery") && html.contains("<figcaption>Ünïcode photo.png"), "image attachment in gallery")
    expect(!html.contains("<figcaption>logo.png"), "cid-shown image not repeated in gallery")
}

test("thread: cover, order, participants, cid scoping") {
    let msgs = try ["rich.eml", "reply.eml", "forward.eml"].map(fixture)
    let html = HTMLBuilder().build(messages: msgs)
    expect(html.contains("Message 1 of 3") && html.contains("Message 3 of 3"), "numbered")
    let r1 = html.range(of: "id=\"msg-1\"")!, r2 = html.range(of: "id=\"msg-2\"")!, r3 = html.range(of: "id=\"msg-3\"")!
    expect(r1.lowerBound < r2.lowerBound && r2.lowerBound < r3.lowerBound, "argument order kept")
    let people = HTMLBuilder.participants(of: msgs).map(\.email)
    expect(people == ["zoe@example.com", "bob@example.com", "carol@example.org", "dana@example.net", "secret-archive@example.com"],
           "participants de-duplicated in order: \(people)")
    expect(HTMLBuilder.threadSubject(of: [msgs[1]]) == "Q3 roadmap — résumé & next steps ✅", "Re: stripped")
    // reply.eml reuses Content-ID logo@example.com for a different image; it must not leak into message 1.
    let red = Attachment(filename: nil, mimeType: "image/png", data: msgs[1].attachments[0].data, contentID: nil, isInline: false)
    let msg1 = String(html[r1.lowerBound..<r2.lowerBound])
    expect(!msg1.contains(HTMLBuilder.dataURI(red)), "cid scoped per message")
}

// MARK: End to end

@MainActor
func renderTests() async {
    print("• PDF rendering (single + thread)")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("eml2pdf-tests-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        let renderer = PDFRenderer(paper: .a4)

        let single = tmp.appendingPathComponent("rich.pdf")
        let rich = try fixture("rich.eml")
        try await renderer.render(html: HTMLBuilder().build(messages: [rich]), to: single, footer: rich.subject)
        let doc = PDFDocument(url: single)
        let text = doc?.string ?? ""
        expect((doc?.pageCount ?? 0) >= 1, "has pages")
        for needle in ["résumé", "zoe@example.com", "bob@example.com", "carol@example.org", "dana@example.net",
                       "secret-archive@example.com", "Q3 Roadmap.pdf", "archive.zip", "Ünïcode photo.png", "Page 1 of"] {
            expect(text.contains(needle), "PDF text contains \(needle)")
        }

        let thread = tmp.appendingPathComponent("thread.pdf")
        let msgs = try ["rich.eml", "reply.eml", "forward.eml"].map(fixture)
        try await renderer.render(html: HTMLBuilder().build(messages: msgs), to: thread)
        let tdoc = PDFDocument(url: thread)!
        expect(tdoc.pageCount >= 4, "cover + one page per message, got \(tdoc.pageCount)")
        let pages = (0..<tdoc.pageCount).map { tdoc.page(at: $0)?.string ?? "" }
        expect(pages[0].contains("Participants") && pages[0].contains("secret-archive@example.com"), "cover lists participants")
        let order = ["MESSAGE 1 OF 3", "MESSAGE 2 OF 3", "MESSAGE 3 OF 3"].map { label in
            pages.firstIndex { $0.uppercased().contains(label) } ?? -1
        }
        expect(order[0] > 0 && order[0] < order[1] && order[1] < order[2], "messages in argument order on separate pages: \(order)")
        expect(pages.joined().contains("quote-4471.pdf"), "embedded message attachment listed")
        let links = tdoc.page(at: 0)?.annotations.filter { $0.destination != nil }.count ?? 0
        expect(links >= 3, "index links survive footer pass (\(links))")
    } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}

_ = NSApplication.shared
Task { @MainActor in
    await renderTests()
    print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks failed.")
    exit(failures == 0 ? 0 : 1)
}
NSApp.run()
