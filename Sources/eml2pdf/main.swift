import AppKit


let usage = """
usage: eml2pdf [options] <file.eml>...

Converts one email to a PDF. When several files are given they are treated as
one email chain, in the order given, and combined into a single PDF.

options:
  -o, --output <path>   output PDF (default: next to the first input)
      --paper a4|letter paper size (default: from your locale)
      --remote-images   allow loading remote images and stylesheets
      --html            write the intermediate HTML instead of a PDF
  -f, --force           overwrite an existing output file
  -h, --help            show this help
"""

struct Options {
    var inputs: [URL] = []
    var output: URL?
    var paper = Paper.localeDefault
    var remote = false
    var htmlOnly = false
    var force = false
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("eml2pdf: \(message)\n".utf8))
    exit(code)
}

/// Absolute file URL; relative URLs make the print system log CFURL warnings.
func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).absoluteURL
}

func parseArguments(_ args: [String]) -> Options {
    var opts = Options()
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "-o", "--output":
            guard let path = it.next() else { fail("\(arg) needs a path") }
            opts.output = fileURL(path)
        case "--paper":
            guard let value = it.next(), let paper = Paper(rawValue: value.lowercased()) else {
                fail("--paper must be one of: \(Paper.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            opts.paper = paper
        case "--remote-images": opts.remote = true
        case "--html": opts.htmlOnly = true
        case "-f", "--force": opts.force = true
        default:
            if arg.hasPrefix("-"), arg != "-" { fail("unknown option \(arg)\n\n\(usage)", code: 2) }
            opts.inputs.append(fileURL(arg))
        }
    }
    if opts.inputs.isEmpty { fail("no input files\n\n\(usage)", code: 2) }
    return opts
}

func defaultOutput(for opts: Options) -> URL {
    let first = opts.inputs[0]
    let base = first.deletingPathExtension().lastPathComponent + (opts.inputs.count > 1 ? "-thread" : "")
    return first.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(opts.htmlOnly ? "html" : "pdf")
}

@MainActor
func run() async {
    let opts = parseArguments(Array(CommandLine.arguments.dropFirst()))

    // Parse everything first so a bad file never produces a partial chain.
    var messages: [EmailMessage] = []
    var errors: [String] = []
    for url in opts.inputs {
        do {
            messages.append(try MIMEParser.parse(contentsOf: url))
        } catch {
            errors.append("\(error)")
        }
    }
    if !errors.isEmpty { fail(errors.joined(separator: "\n")) }

    let output = opts.output ?? defaultOutput(for: opts)
    if FileManager.default.fileExists(atPath: output.path) {
        if !opts.force { fail("\(output.path) already exists (use -f to overwrite)") }
        try? FileManager.default.removeItem(at: output)
    }

    let html = HTMLBuilder(allowRemoteContent: opts.remote).build(messages: messages)
    do {
        if opts.htmlOnly {
            try html.write(to: output, atomically: true, encoding: .utf8)
        } else {
            try await PDFRenderer(paper: opts.paper, allowRemoteContent: opts.remote).render(html: html, to: output, footer: HTMLBuilder.threadSubject(of: messages))
        }
    } catch {
        fail("\(output.lastPathComponent): \(error)")
    }
    print(output.path)
    exit(0)
}

_ = NSApplication.shared
Task { @MainActor in await run() }
NSApp.run()
