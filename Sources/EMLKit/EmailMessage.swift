import Foundation

public struct Attachment: Sendable {
    public var filename: String?
    public var mimeType: String
    public var data: Data
    public var contentID: String?
    /// True for parts embedded in the body (Content-ID images) rather than offered as downloads.
    public var isInline: Bool

    public var size: Int { data.count }
    public var isImage: Bool { mimeType.hasPrefix("image/") }

    public var displayName: String {
        if let filename, !filename.isEmpty { return filename }
        if let contentID { return contentID }
        return "untitled (\(mimeType))"
    }
}

/// One renderable piece of a message body, in document order.
public enum BodySegment: Sendable {
    case html(String)
    case text(String)
}

public struct EmailMessage: Sendable {
    public var subject: String = ""
    public var from: [EmailAddress] = []
    public var sender: [EmailAddress] = []
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var replyTo: [EmailAddress] = []
    public var date: Date?
    public var rawDate: String?
    public var messageID: String?

    public var body: [BodySegment] = []
    /// Every non-body part, in MIME order. Includes inline images.
    public var attachments: [Attachment] = []
    /// Attached `message/rfc822` parts, parsed.
    public var embeddedMessages: [EmailMessage] = []

    public init() {}

    public var participants: [EmailAddress] { from + to + cc + bcc }

    /// Inline parts addressable through `cid:` URLs, keyed by Content-ID without angle brackets.
    public var contentIDMap: [String: Attachment] {
        var map: [String: Attachment] = [:]
        for a in attachments {
            if let cid = a.contentID { map[cid] = a }
        }
        return map
    }
}

public enum EMLError: Error, CustomStringConvertible {
    case unreadable(URL, Error)
    case notAnEmail(URL)

    public var description: String {
        switch self {
        case let .unreadable(url, err): return "\(url.path): \(err.localizedDescription)"
        case let .notAnEmail(url): return "\(url.path): does not look like an email (no headers found)"
        }
    }
}
