import Foundation

/// Turns parsed messages into one self-contained, print-ready HTML document.
public struct HTMLBuilder {
    public var allowRemoteContent: Bool

    public init(allowRemoteContent: Bool = false) {
        self.allowRemoteContent = allowRemoteContent
    }

    /// One message gives a plain document; several give a thread with a cover page and index.
    public func build(messages: [EmailMessage]) -> String {
        var html = "<!doctype html><html><head><meta charset=\"utf-8\">"
        html += "<title>\(esc(Self.threadSubject(of: messages)))</title>"
        html += "<style>\(Self.css)</style></head><body>"

        let isThread = messages.count > 1
        if isThread {
            html += cover(messages)
        }
        for (i, msg) in messages.enumerated() {
            let label = isThread ? "Message \(i + 1) of \(messages.count)" : nil
            let pageBreak = isThread ? " e2p-break" : ""
            html += "<section class=\"e2p-message\(pageBreak)\" id=\"msg-\(i + 1)\">"
            html += render(msg, scope: "m\(i + 1)", label: label)
            html += "</section>"
        }
        html += "</body></html>"
        return html
    }

    // MARK: Thread cover

    static func threadSubject(of messages: [EmailMessage]) -> String {
        let subject = messages.first?.subject ?? ""
        let stripped = subject.replacingOccurrences(
            of: #"^\s*((re|fw|fwd|aw|sv|wg|tr)(\[\d+\])?\s*:\s*)+"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return stripped.isEmpty ? (subject.isEmpty ? "(no subject)" : subject) : stripped
    }

    /// Unique participants across the thread, in first-seen order, preferring entries that have a name.
    static func participants(of messages: [EmailMessage]) -> [EmailAddress] {
        var order: [String] = []
        var byKey: [String: EmailAddress] = [:]
        for addr in messages.flatMap(\.participants) {
            let key = addr.email.lowercased()
            if let existing = byKey[key] {
                if (existing.name ?? "").isEmpty, !(addr.name ?? "").isEmpty { byKey[key] = addr }
            } else {
                order.append(key)
                byKey[key] = addr
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private func cover(_ messages: [EmailMessage]) -> String {
        var h = "<section class=\"e2p-cover\">"
        h += "<div class=\"e2p-kicker\">Email thread</div>"
        h += "<h1 class=\"e2p-cover-title\">\(esc(Self.threadSubject(of: messages)))</h1>"

        var facts = ["\(messages.count) messages"]
        let dates = messages.compactMap(\.date)
        if let first = dates.min(), let last = dates.max() {
            facts.append(first == last ? formatDate(first) : "\(formatDate(first)) – \(formatDate(last))")
        }
        h += "<p class=\"e2p-facts\">\(facts.map(esc).joined(separator: " · "))</p>"

        let people = Self.participants(of: messages)
        h += "<h2>Participants</h2><ul class=\"e2p-people\">"
        h += people.map { "<li>\(esc($0.display))</li>" }.joined()
        h += "</ul>"

        h += "<h2>Messages</h2><table class=\"e2p-index\"><thead><tr><th>#</th><th>From</th><th>Date</th><th>Subject</th></tr></thead><tbody>"
        for (i, m) in messages.enumerated() {
            let from = m.from.first.map { ($0.name?.isEmpty == false ? $0.name! : $0.email) } ?? "—"
            let date = m.date.map { formatDate($0) } ?? (m.rawDate ?? "—")
            let clip = m.attachments.contains { !$0.isInline } ? " <span class=\"e2p-clip\">📎</span>" : ""
            h += "<tr><td><a href=\"#msg-\(i + 1)\">\(i + 1)</a></td><td>\(esc(from))</td>"
            h += "<td class=\"e2p-nowrap\">\(esc(date))</td>"
            h += "<td><a href=\"#msg-\(i + 1)\">\(esc(m.subject.isEmpty ? "(no subject)" : m.subject))</a>\(clip)</td></tr>"
        }
        h += "</tbody></table></section>"
        return h
    }

    // MARK: Message

    private func render(_ msg: EmailMessage, scope: String, label: String?) -> String {
        let cids = msg.contentIDMap
        var usedCIDs = Set<String>()
        var bodyHTML = ""
        var styles = ""
        for segment in msg.body {
            switch segment {
            case let .html(raw):
                let prepared = prepareHTML(raw, scope: scope, cids: cids, used: &usedCIDs)
                styles += prepared.styles
                bodyHTML += "<div class=\"e2p-html\">\(prepared.body)</div>"
            case let .text(raw):
                bodyHTML += "<div class=\"e2p-plain\">\(plainTextHTML(raw))</div>"
            }
        }

        var h = header(msg, label: label)
        h += attachmentList(msg, usedCIDs: usedCIDs)
        if !styles.isEmpty { h += "<style>\(styles)</style>" }
        h += "<div class=\"email-content \(scope)\">\(bodyHTML.isEmpty ? "<p class=\"e2p-empty\">(no message body)</p>" : bodyHTML)</div>"
        h += gallery(msg, usedCIDs: usedCIDs)

        for (i, nested) in msg.embeddedMessages.enumerated() {
            h += "<div class=\"e2p-embedded\"><div class=\"e2p-kicker\">Attached message</div>"
            h += render(nested, scope: "\(scope)-e\(i + 1)", label: nil)
            h += "</div>"
        }
        return h
    }

    private func header(_ msg: EmailMessage, label: String?) -> String {
        var h = "<div class=\"e2p-card\">"
        if let label { h += "<div class=\"e2p-kicker\">\(esc(label))</div>" }
        h += "<h1 class=\"e2p-subject\">\(esc(msg.subject.isEmpty ? "(no subject)" : msg.subject))</h1>"
        h += "<table class=\"e2p-meta\">"
        let rows: [(String, [EmailAddress])] = [
            ("From", msg.from), ("Sender", msg.sender.filter { !msg.from.contains($0) }),
            ("To", msg.to), ("Cc", msg.cc), ("Bcc", msg.bcc), ("Reply-To", msg.replyTo),
        ]
        for (name, list) in rows where !list.isEmpty {
            h += "<tr><th>\(name)</th><td>\(list.map { esc($0.display) }.joined(separator: ", "))</td></tr>"
        }
        if let date = msg.date {
            h += "<tr><th>Date</th><td>\(esc(formatDate(date, style: .full)))</td></tr>"
        } else if let raw = msg.rawDate {
            h += "<tr><th>Date</th><td>\(esc(raw))</td></tr>"
        }
        h += "</table></div>"
        return h
    }

    private func attachmentList(_ msg: EmailMessage, usedCIDs: Set<String>) -> String {
        // Unnamed inline images (signature logos etc.) shown in the body aren't worth listing.
        let listed = msg.attachments.filter { a in
            !(a.isInline && a.filename == nil && a.contentID.map(usedCIDs.contains) == true)
        }
        guard !listed.isEmpty else { return "" }
        var h = "<div class=\"e2p-attachments\"><div class=\"e2p-att-title\">📎 \(listed.count) attachment\(listed.count == 1 ? "" : "s")</div><ul>"
        for a in listed {
            var tags = [a.mimeType, Self.formatSize(a.size)]
            if a.isInline { tags.append("inline") }
            h += "<li><span class=\"e2p-att-name\">\(esc(a.displayName))</span> <span class=\"e2p-att-meta\">\(esc(tags.joined(separator: " · ")))</span></li>"
        }
        h += "</ul></div>"
        return h
    }

    private func gallery(_ msg: EmailMessage, usedCIDs: Set<String>) -> String {
        let images = msg.attachments.filter { a in
            Self.imageMIMEType(for: a) != nil && !(a.contentID.map(usedCIDs.contains) ?? false)
        }
        guard !images.isEmpty else { return "" }
        var h = "<div class=\"e2p-gallery\"><div class=\"e2p-att-title\">Images</div>"
        for a in images {
            h += "<figure><img src=\"\(Self.dataURI(a))\" alt=\"\(esc(a.displayName))\">"
            h += "<figcaption>\(esc(a.displayName))</figcaption></figure>"
        }
        h += "</div>"
        return h
    }

    // MARK: Body preparation

    private func prepareHTML(_ raw: String, scope: String, cids: [String: Attachment], used: inout Set<String>) -> (styles: String, body: String) {
        var html = raw
        let ci: NSString.CompareOptions = [.regularExpression, .caseInsensitive]

        // Remove active or document-level content.
        for pattern in [
            #"<script\b[^>]*>[\s\S]*?</script\s*>"#,
            #"<(iframe|object|applet|frameset|noscript)\b[^>]*>[\s\S]*?</\1\s*>"#,
            #"<(iframe|object|embed|applet|frame|frameset|base|meta)\b[^>]*>"#,
            #"<title\b[^>]*>[\s\S]*?</title\s*>"#,
        ] {
            html = html.replacingOccurrences(of: pattern, with: "", options: ci)
        }
        if !allowRemoteContent {
            html = html.replacingOccurrences(of: #"<link\b[^>]*>"#, with: "", options: ci)
        }
        html = html.replacingOccurrences(of: #"\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: ci)
        html = html.replacingOccurrences(of: #"\s(href|src)\s*=\s*("\s*javascript:[^"]*"|'\s*javascript:[^']*'|javascript:[^\s>]*)"#, with: "", options: ci)

        // Rewrite cid: references to embedded data URIs.
        html = Self.replaceMatches(in: html, pattern: #"cid:([^"'\s)>]+)"#) { groups in
            let key = groups[1].removingPercentEncoding ?? groups[1]
            guard let att = cids[key] ?? cids[groups[1]] else { return groups[0] }
            used.insert(att.contentID ?? key)
            return Self.dataURI(att)
        }

        // Pull out style blocks and scope their html/body selectors to this message's container.
        var styles = ""
        html = Self.replaceMatches(in: html, pattern: #"<style\b[^>]*>([\s\S]*?)</style\s*>"#) { groups in
            styles += Self.scopeCSS(groups[1], scope: scope) + "\n"
            return ""
        }

        // Keep only the <body> contents when it's a full document.
        if let range = html.range(of: #"<body\b[^>]*>([\s\S]*)</body\s*>"#, options: ci) {
            html = String(html[range])
                .replacingOccurrences(of: #"^<body\b[^>]*>"#, with: "", options: ci)
                .replacingOccurrences(of: #"</body\s*>$"#, with: "", options: ci)
        } else {
            for pattern in [#"<head\b[^>]*>[\s\S]*?</head\s*>"#, #"</?(html|body|head)\b[^>]*>"#, #"<!doctype[^>]*>"#] {
                html = html.replacingOccurrences(of: pattern, with: "", options: ci)
            }
        }
        return (styles, html)
    }

    /// Points `html`/`body`/`:root` selectors in email CSS at the message's own container
    /// so they don't restyle the surrounding document.
    static func scopeCSS(_ css: String, scope: String) -> String {
        var out = css.replacingOccurrences(of: "<!--", with: "").replacingOccurrences(of: "-->", with: "")
        out = out.replacingOccurrences(
            of: #"(^|[\s,{}>+~])(html|body|:root)(?=[\s,{.#:\[>+~])"#,
            with: "$1.email-content.\(scope)", options: [.regularExpression, .caseInsensitive]
        )
        return out
    }

    private func plainTextHTML(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var escaped = esc(String(line))
            escaped = escaped.replacingOccurrences(
                of: #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]])"#,
                with: "<a href=\"$1\">$1</a>", options: .regularExpression
            )
            return line.hasPrefix(">") ? "<span class=\"e2p-quote\">\(escaped)</span>" : escaped
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    static func replaceMatches(in s: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// The MIME type to use when displaying an attachment as an image, or nil if it isn't one.
    static func imageMIMEType(for a: Attachment) -> String? {
        let displayable: Set<String> = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
                                        "image/heic", "image/heif", "image/tiff", "image/bmp", "image/svg+xml"]
        if displayable.contains(a.mimeType) { return a.mimeType == "image/jpg" ? "image/jpeg" : a.mimeType }
        let ext = (a.filename as NSString?)?.pathExtension.lowercased() ?? ""
        let byExt = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff",
                     "tiff": "image/tiff", "bmp": "image/bmp"]
        if a.mimeType.hasPrefix("image/") || a.mimeType == "application/octet-stream" {
            return byExt[ext]
        }
        return nil
    }

    static func dataURI(_ a: Attachment) -> String {
        let type = imageMIMEType(for: a) ?? a.mimeType
        return "data:\(type);base64,\(a.data.base64EncodedString())"
    }

    static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formatDate(_ date: Date, style: DateFormatter.Style = .medium) -> String {
        let f = DateFormatter()
        f.dateStyle = style
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: Stylesheet

    static let css = """
    html { -webkit-print-color-adjust: exact; }
    body { margin: 0; font: 10.5pt/1.45 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1d1d1f; background: #fff; }
    .e2p-break { break-before: page; }
    .e2p-kicker { font-size: 8pt; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: #86868b; margin-bottom: 4px; }
    .e2p-card { background: #f5f5f7; border: 1px solid #d2d2d7; border-radius: 10px; padding: 14px 16px 10px; margin: 0 0 12px; break-inside: avoid; }
    h1.e2p-subject { font-size: 16pt; line-height: 1.25; font-weight: 600; margin: 0 0 10px; color: #1d1d1f; }
    table.e2p-meta { border-collapse: collapse; width: 100%; font-size: 9.5pt; }
    table.e2p-meta th { text-align: right; vertical-align: top; color: #6e6e73; font-weight: 500; width: 64px; padding: 2px 10px 2px 0; white-space: nowrap; }
    table.e2p-meta td { padding: 2px 0; word-break: break-word; }
    .e2p-attachments { border: 1px solid #d2d2d7; border-radius: 10px; padding: 10px 16px; margin: 0 0 14px; font-size: 9.5pt; break-inside: avoid; }
    .e2p-att-title { font-weight: 600; margin-bottom: 4px; }
    .e2p-attachments ul { margin: 0; padding-left: 18px; }
    .e2p-attachments li { margin: 2px 0; word-break: break-word; }
    .e2p-att-meta { color: #86868b; font-size: 8.5pt; }
    .email-content { overflow-wrap: break-word; }
    .email-content img { max-width: 100% !important; height: auto; }
    .email-content table { max-width: 100% !important; }
    .email-content pre { white-space: pre-wrap; }
    .e2p-plain { white-space: pre-wrap; }
    .e2p-quote { color: #6e6e73; }
    .e2p-empty { color: #86868b; font-style: italic; }
    .e2p-gallery { margin-top: 18px; border-top: 1px solid #d2d2d7; padding-top: 10px; }
    .e2p-gallery figure { margin: 10px 0 16px; break-inside: avoid; text-align: center; }
    .e2p-gallery img { max-width: 100%; max-height: 230mm; border: 1px solid #e5e5ea; border-radius: 4px; }
    .e2p-gallery figcaption { font-size: 8.5pt; color: #6e6e73; margin-top: 4px; }
    .e2p-embedded { margin-top: 18px; padding-left: 12px; border-left: 3px solid #d2d2d7; }
    .e2p-cover h1.e2p-cover-title { font-size: 22pt; font-weight: 650; margin: 0 0 4px; }
    .e2p-cover h2 { font-size: 11pt; margin: 20px 0 6px; padding-bottom: 4px; border-bottom: 1px solid #d2d2d7; }
    .e2p-facts { color: #6e6e73; margin: 0; }
    ul.e2p-people { margin: 0; padding-left: 18px; columns: 2; font-size: 9.5pt; }
    table.e2p-index { width: 100%; border-collapse: collapse; font-size: 9.5pt; }
    table.e2p-index th { text-align: left; color: #6e6e73; font-weight: 500; border-bottom: 1px solid #d2d2d7; padding: 4px 8px 4px 0; }
    table.e2p-index td { vertical-align: top; border-bottom: 1px solid #ececf0; padding: 4px 8px 4px 0; }
    table.e2p-index a { color: inherit; text-decoration: none; }
    .e2p-nowrap { white-space: nowrap; }
    """
}
