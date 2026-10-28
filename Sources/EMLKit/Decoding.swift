import Foundation

enum Decoding {
    /// Maps an IANA charset name to a Foundation string encoding.
    static func encoding(forCharset name: String?) -> String.Encoding? {
        guard var name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return nil
        }
        // Common aliases CoreFoundation doesn't know about.
        switch name {
        case "utf8": name = "utf-8"
        case "latin1": name = "iso-8859-1"
        case "ks_c_5601-1987": name = "euc-kr"
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Decodes bytes as text using the declared charset, falling back to UTF-8, then Windows-1252/Latin-1.
    static func string(from data: Data, charset: String?) -> String {
        if let enc = encoding(forCharset: charset), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func base64(_ data: Data) -> Data {
        let filtered = data.filter { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2F || byte == 0x3D
        }
        var trimmed = Data(filtered.prefix { $0 != 0x3D })
        // Re-pad to a multiple of four; tolerate missing or excess padding.
        let remainder = trimmed.count % 4
        if remainder == 1 { trimmed.removeLast() }
        if remainder > 1 { trimmed.append(contentsOf: Array(repeating: 0x3D, count: 4 - remainder)) }
        return Data(base64Encoded: trimmed) ?? Data()
    }

    /// Quoted-printable decoding (RFC 2045). With `underscoreIsSpace` it handles the RFC 2047 "Q" variant.
    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                // Soft line break: "=\r\n" or "=\n" (possibly with trailing whitespace before it).
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j < bytes.count, bytes[j] == 0x0D || bytes[j] == 0x0A {
                    if bytes[j] == 0x0D, j + 1 < bytes.count, bytes[j + 1] == 0x0A { j += 1 }
                    i = j + 1
                    continue
                }
                if j >= bytes.count { break }
                if i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                out.append(b)
                i += 1
            } else if underscoreIsSpace, b == 0x5F {
                out.append(0x20)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// Decodes %XX escapes used by RFC 2231 parameter values.
    static func percent(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var out = Data()
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
