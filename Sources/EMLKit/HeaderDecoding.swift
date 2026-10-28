import Foundation

public struct EmailAddress: Hashable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    /// "Name <email>", or just the email when there is no distinct display name.
    public var display: String {
        if let name, !name.isEmpty, name.caseInsensitiveCompare(email) != .orderedSame {
            return email.isEmpty ? name : "\(name) <\(email)>"
        }
        return email
    }
}

/// A header value split into its main value and `; key=value` parameters, e.g. Content-Type.
struct HeaderValue {
    var value: String
    var params: [String: String]
}

enum HeaderDecoding {
    // MARK: RFC 2047 encoded-words

    private static let encodedWord = try! NSRegularExpression(
        pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
    )

    /// Decodes RFC 2047 encoded-words, dropping whitespace between adjacent encoded-words.
    static func decodeWords(_ input: String) -> String {
        let ns = input as NSString
        let matches = encodedWord.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        var lastWasEncoded = false
        for m in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !(lastWasEncoded && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += gap
            }
            var charset = ns.substring(with: m.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231 language
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = Data(ns.substring(with: m.range(at: 3)).utf8)
            let bytes = mode == "B" ? Decoding.base64(text) : Decoding.quotedPrintable(text, underscoreIsSpace: true)
            result += Decoding.string(from: bytes, charset: charset)
            cursor = m.range.location + m.range.length
            lastWasEncoded = true
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: Parameters (RFC 2045 / RFC 2231)

    /// Splits on `separator`, ignoring separators inside double quotes, angle brackets or comments.
    static func split(_ s: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        var paren = 0
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\" where inQuotes:
                escaped = true
            case "\"" where paren == 0:
                inQuotes.toggle()
            case "<" where !inQuotes && paren == 0: angle += 1
            case ">" where !inQuotes && paren == 0: angle = max(0, angle - 1)
            case "(" where !inQuotes: paren += 1
            case ")" where !inQuotes: paren = max(0, paren - 1)
            default: break
            }
            if ch == separator, !inQuotes, angle == 0, paren == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
            t = t.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        }
        return t
    }

    static func parseHeaderValue(_ raw: String) -> HeaderValue {
        let parts = split(raw, on: ";")
        let value = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var plain: [String: String] = [:]
        // RFC 2231 continuations: name*0, name*1*, ... collected then joined in order.
        var continuations: [String: [(index: Int, value: String, encoded: Bool)]] = [:]

        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let rawVal = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var encoded = false
            if key.hasSuffix("*") {
                encoded = true
                key.removeLast()
            }
            if let star = key.firstIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: []].append((index, unquote(rawVal), encoded))
            } else if encoded {
                continuations[key, default: []].append((0, unquote(rawVal), true))
            } else {
                plain[key] = unquote(rawVal)
            }
        }

        for (key, pieces) in continuations {
            let sorted = pieces.sorted { $0.index < $1.index }
            var charset: String?
            var bytes = Data()
            for (i, piece) in sorted.enumerated() {
                var v = piece.value
                if piece.encoded, i == 0 {
                    // charset'language'value
                    let comps = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if comps.count == 3 {
                        charset = String(comps[0])
                        v = String(comps[2])
                    }
                }
                bytes.append(piece.encoded ? Decoding.percent(v) : Data(v.utf8))
            }
            plain[key] = Decoding.string(from: bytes, charset: charset ?? "utf-8")
        }

        // Many mailers put RFC 2047 encoded-words inside quoted filenames, against the spec.
        for (k, v) in plain where v.contains("=?") {
            plain[k] = decodeWords(v)
        }
        return HeaderValue(value: value, params: plain)
    }

    // MARK: Address lists

    static func parseAddressList(_ raw: String) -> [EmailAddress] {
        var flattened = raw
        // Strip group syntax "Group name: a@b, c@d;" down to its members.
        if let colon = groupColon(in: flattened) {
            flattened = String(flattened[flattened.index(after: colon)...])
            flattened = flattened.replacingOccurrences(of: ";", with: ",")
        }
        return split(flattened, on: ",").compactMap(parseAddress)
    }

    private static func groupColon(in s: String) -> String.Index? {
        var inQuotes = false
        var angle = 0
        for idx in s.indices {
            let ch = s[idx]
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if ch == "<" { angle += 1 }
                if ch == ">" { angle -= 1 }
                if ch == ":", angle == 0 { return idx }
            }
        }
        return nil
    }

    static func parseAddress(_ raw: String) -> EmailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let lt = s.lastIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            let email = unquote(s[s.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces))
            let name = decodeWords(unquote(String(s[..<lt]))).trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: name.isEmpty ? nil : name, email: email)
        }
        // "email (Comment Name)"
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let email = s[..<open].trimmingCharacters(in: .whitespaces)
            let name = decodeWords(String(s[s.index(after: open)..<close]))
            return EmailAddress(name: name.isEmpty ? nil : name, email: email)
        }
        return EmailAddress(name: nil, email: decodeWords(unquote(s)))
    }

    // MARK: Dates

    static func parseDate(_ raw: String) -> Date? {
        // Drop trailing comments like "(UTC)" and collapse whitespace.
        var s = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yy HH:mm:ss Z",
        ]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            fmt.dateFormat = f
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }
}
