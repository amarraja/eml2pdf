import AppKit
import PDFKit
import WebKit

public enum Paper: String, CaseIterable, Sendable {
    case a4, letter

    /// Letter for US/Canada/Mexico-style locales, A4 elsewhere.
    public static var localeDefault: Paper {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "GT", "CR", "PA", "SV", "DO", "BZ"]
        return letterRegions.contains(Locale.current.region?.identifier ?? "") ? .letter : .a4
    }

    var size: NSSize {
        switch self {
        case .a4: return NSSize(width: 595.28, height: 841.89)
        case .letter: return NSSize(width: 612, height: 792)
        }
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case loadFailed(Error)
    case printFailed

    public var description: String {
        switch self {
        case let .loadFailed(err): return "could not lay out the email: \(err.localizedDescription)"
        case .printFailed: return "WebKit failed to produce the PDF"
        }
    }
}

/// Renders HTML into a paginated PDF using an offscreen WKWebView and the AppKit print system.
@MainActor
public final class PDFRenderer: NSObject, WKNavigationDelegate {
    public let paper: Paper
    public let allowRemoteContent: Bool

    private let margins = NSEdgeInsets(top: 36, left: 40, bottom: 40, right: 40)
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    public init(paper: Paper = .localeDefault, allowRemoteContent: Bool = false) {
        self.paper = paper
        self.allowRemoteContent = allowRemoteContent
        super.init()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    /// Renders `html` to `output`. `footer` is printed at the bottom-left of every page beside the page number.
    public func render(html: String, to output: URL, footer: String = "") async throws {
        let contentSize = NSSize(
            width: paper.size.width - margins.left - margins.right,
            height: paper.size.height - margins.top - margins.bottom
        )
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        if !allowRemoteContent, let rules = try await Self.blockRemoteRules() {
            config.userContentController.add(rules)
        }

        let frame = NSRect(origin: .zero, size: contentSize)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            webView.loadHTMLString(html, baseURL: nil)
        }
        _ = try? await webView.callAsyncJavaScript(Self.prepareScript, contentWorld: .page)

        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output,
        ])
        info.paperSize = paper.size
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = webView.bounds

        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            printContinuation = c
            op.runModal(for: window, delegate: self,
                        didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok, FileManager.default.fileExists(atPath: output.path) else { throw RenderError.printFailed }
        try addPageFooters(to: output, title: footer)
    }

    /// Stamps "Page n of N" (and a title) on every page. Drawing happens through a PDFPage subclass
    /// so existing link annotations are preserved when the document is written back.
    private func addPageFooters(to url: URL, title: String) throws {
        guard let doc = PDFDocument(url: url) else { throw RenderError.printFailed }
        let delegate = FooterPageDelegate()
        doc.delegate = delegate
        FooterPage.title = title
        FooterPage.bottomMargin = margins.bottom
        FooterPage.sideMargin = margins.left
        guard doc.pageCount > 0, doc.page(at: 0) is FooterPage, doc.write(to: url) else {
            throw RenderError.printFailed
        }
    }

    /// Waits for images to decode, then shrinks any message body that is wider than the page.
    private static let prepareScript = """
    await Promise.all(Array.from(document.images).map(i => i.decode().catch(() => {})));
    for (const el of document.querySelectorAll('.email-content')) {
      const w = el.clientWidth, sw = el.scrollWidth;
      if (w > 0 && sw > w + 1) el.style.zoom = (w / sw).toFixed(4);
    }
    return true;
    """

    private static func blockRemoteRules() async throws -> WKContentRuleList? {
        // Content rule regexes don't support alternation, so one rule per scheme.
        let rules = ["^https?://", "^wss?://", "^ftp://"].map {
            #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
        }
        let json = "[\(rules.joined(separator: ","))]"
        return try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "eml2pdf-block-remote", encodedContentRuleList: json)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printContinuation?.resume(returning: success)
        printContinuation = nil
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: RenderError.loadFailed(error))
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: RenderError.loadFailed(error))
        loadContinuation = nil
    }
}

private final class FooterPageDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { FooterPage.self }
}

private final class FooterPage: PDFPage {
    nonisolated(unsafe) static var title = ""
    nonisolated(unsafe) static var bottomMargin: CGFloat = 40
    nonisolated(unsafe) static var sideMargin: CGFloat = 40

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard let doc = document else { return }
        let bounds = self.bounds(for: box)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5),
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ]
        let pageLabel = NSAttributedString(string: "Page \(doc.index(for: self) + 1) of \(doc.pageCount)", attributes: attrs)
        let y = bounds.minY + Self.bottomMargin / 2 - 4
        let labelWidth = pageLabel.size().width

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        pageLabel.draw(in: NSRect(x: bounds.maxX - Self.sideMargin - labelWidth, y: y, width: labelWidth + 1, height: 12))
        if !Self.title.isEmpty {
            let maxWidth = bounds.width - 2 * Self.sideMargin - labelWidth - 24
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            var titleAttrs = attrs
            titleAttrs[.paragraphStyle] = para
            NSAttributedString(string: Self.title, attributes: titleAttrs)
                .draw(in: NSRect(x: bounds.minX + Self.sideMargin, y: y, width: maxWidth, height: 12))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
