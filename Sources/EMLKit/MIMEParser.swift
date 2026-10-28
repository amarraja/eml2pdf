import Foundation

/// A raw MIME entity: headers plus undecoded body bytes.
struct MIMEPart {
    var headers: [(name: String, value: String)]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: HeaderValue {
        HeaderDecoding.parseHeaderValue(header("Content-Type") ?? "text/plain; charset=us-ascii")
    }

    var mimeType: String {
        let t = contentType.value.lowercased()
        return t.contains("/") ? t : "text/plain"
    }

    var disposition: HeaderValue? {
        header("Content-Disposition").map(HeaderDecoding.parseHeaderValue)
    }

    var filename: String? {
        let name = disposition?.params["filename"] ?? contentType.params["name"]
        return name.map { HeaderDecoding.decodeWords($0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var contentID: String? {
        guard let raw = header("Content-ID") ?? header("X-Attachment-Id") else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Body bytes with the Content-Transfer-Encoding removed.
    var decodedBody: Data {
        switch header("Content-Transfer-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return Decoding.base64(body)
        case "quoted-printable": return Decoding.quotedPrintable(body)
        default: return body
        }
    }

    var text: String {
        Decoding.string(from: decodedBody, charset: contentType.params["charset"])
    }
}

public enum MIMEParser {
    public static func parse(contentsOf url: URL) throws -> EmailMessage {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EMLError.unreadable(url, error)
        }
        let part = parsePart(normalizeNewlines(data))
        guard !part.headers.isEmpty else { throw EMLError.notAnEmail(url) }
        return message(from: part)
    }

    public static func parse(data: Data) -> EmailMessage {
        message(from: parsePart(normalizeNewlines(data)))
    }

    // MARK: Raw structure

    /// Converts CRLF and bare CR to LF so the rest of the parser only deals with "\n".
    static func normalizeNewlines(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var prevCR = false
        for b in data {
            if b == 0x0D {
                out.append(0x0A)
                prevCR = true
            } else {
                if !(b == 0x0A && prevCR) { out.append(b) }
                prevCR = false
            }
        }
        return out
    }

    static func parsePart(_ data: Data) -> MIMEPart {
        let bytes = [UInt8](data)
        // Skip leading blank lines and an mbox "From " envelope line if present.
        var start = 0
        while start < bytes.count, bytes[start] == 0x0A { start += 1 }
        if bytes.count - start > 5, Array(bytes[start..<start + 5]) == Array("From ".utf8) {
            start = (bytes[start...].firstIndex(of: 0x0A) ?? bytes.count - 1) + 1
        }

        // Header block ends at the first empty line.
        var headerEnd = bytes.count
        var bodyStart = bytes.count
        var i = start
        if i < bytes.count, bytes[i] == 0x0A { // no headers at all
            return MIMEPart(headers: [], body: Data(bytes[(i + 1)...]))
        }
        while i < bytes.count {
            if bytes[i] == 0x0A, i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                headerEnd = i
                bodyStart = i + 2
                break
            }
            i += 1
        }
        let headerData = Data(bytes[start..<min(headerEnd, bytes.count)])
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()

        // Raw 8-bit headers are usually UTF-8; fall back to Latin-1.
        let headerText = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1) ?? ""
        let headers = parseHeaders(headerText)
        // Something that isn't header-shaped is treated as a headerless text body.
        if headers.isEmpty {
            return MIMEPart(headers: [], body: Data(bytes[start...]))
        }
        return MIMEPart(headers: headers, body: body)
    }

    static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                // Folded continuation line.
                if !headers.isEmpty {
                    headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return headers
    }

    /// Splits a multipart body on its boundary, discarding the preamble and epilogue.
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Array("--\(boundary)".utf8)
        let bytes = [0x0A] + [UInt8](body) // so the first delimiter is also preceded by "\n"
        var parts: [Data] = []
        var partStart: Int?
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x0A, i + 1 + delimiter.count <= bytes.count,
                  Array(bytes[(i + 1)..<(i + 1 + delimiter.count)]) == delimiter
            else {
                i += 1
                continue
            }
            let afterDelim = i + 1 + delimiter.count
            if let s = partStart {
                parts.append(Data(bytes[s..<i]))
            }
            let isClose = afterDelim + 1 < bytes.count && bytes[afterDelim] == 0x2D && bytes[afterDelim + 1] == 0x2D
            if isClose { return parts }
            // Skip transport padding to the end of the delimiter line.
            var lineEnd = afterDelim
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            partStart = lineEnd + 1
            i = lineEnd
        }
        // Missing close delimiter: keep the last part anyway.
        if let s = partStart, s < bytes.count {
            parts.append(Data(bytes[s...]))
        }
        return parts
    }

    // MARK: Message model

    static func message(from root: MIMEPart) -> EmailMessage {
        var msg = EmailMessage()
        let decode = { (name: String) in root.header(name).map(HeaderDecoding.decodeWords) }
        let addresses = { (name: String) in
            root.header(name).map(HeaderDecoding.parseAddressList) ?? []
        }
        msg.subject = decode("Subject")?.trimmingCharacters(in: .whitespaces) ?? ""
        msg.from = addresses("From")
        msg.sender = addresses("Sender")
        msg.to = addresses("To")
        msg.cc = addresses("Cc")
        msg.bcc = addresses("Bcc")
        msg.replyTo = addresses("Reply-To")
        msg.rawDate = root.header("Date")
        msg.date = msg.rawDate.flatMap(HeaderDecoding.parseDate)
        msg.messageID = root.header("Message-ID")

        var collector = Collector()
        collector.walk(root)
        msg.body = collector.body
        msg.attachments = collector.attachments
        msg.embeddedMessages = collector.embedded
        return msg
    }

    /// Walks the MIME tree, sorting leaves into body segments and attachments.
    struct Collector {
        var body: [BodySegment] = []
        var attachments: [Attachment] = []
        var embedded: [EmailMessage] = []

        var hasHTML: Bool {
            body.contains { if case .html = $0 { return true } else { return false } }
        }

        mutating func walk(_ part: MIMEPart) {
            let type = part.mimeType

            if type.hasPrefix("multipart/") {
                guard let boundary = part.contentType.params["boundary"], !boundary.isEmpty else {
                    // Broken multipart: show it as text rather than losing it.
                    body.append(.text(part.text))
                    return
                }
                let children = MIMEParser.splitMultipart(part.body, boundary: boundary).map(MIMEParser.parsePart)
                if type == "multipart/alternative" {
                    walkAlternative(children)
                } else {
                    for child in children { walk(child) }
                }
                return
            }

            let dispositionType = part.disposition?.value.lowercased()
            let isAttachmentDisposition = dispositionType == "attachment"

            if type == "message/rfc822" || type == "message/global" {
                let inner = MIMEParser.parsePart(MIMEParser.normalizeNewlines(part.decodedBody))
                let nested = MIMEParser.message(from: inner)
                embedded.append(nested)
                let name = part.filename ?? (nested.subject.isEmpty ? "message.eml" : "\(nested.subject).eml")
                attachments.append(Attachment(
                    filename: name, mimeType: type, data: part.decodedBody,
                    contentID: part.contentID, isInline: false
                ))
                return
            }

            if (type == "text/html" || type == "text/plain"), !isAttachmentDisposition, part.filename == nil {
                body.append(type == "text/html" ? .html(part.text) : .text(part.text))
                return
            }

            attachments.append(Attachment(
                filename: part.filename,
                mimeType: type,
                data: part.decodedBody,
                contentID: part.contentID,
                isInline: part.contentID != nil && !isAttachmentDisposition
            ))
        }

        /// Picks the richest alternative (HTML over text; later parts win ties, per RFC 2046).
        mutating func walkAlternative(_ children: [MIMEPart]) {
            var options: [Collector] = []
            for child in children {
                var c = Collector()
                c.walk(child)
                options.append(c)
            }
            let chosen = options.last(where: { $0.hasHTML })
                ?? options.last(where: { !$0.body.isEmpty })
                ?? options.last
            guard let chosen else { return }
            body += chosen.body
            attachments += chosen.attachments
            embedded += chosen.embedded
        }
    }
}
