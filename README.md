# eml2pdf

A native macOS command-line tool that converts `.eml` emails into clean, paginated PDFs.
It has no dependencies: MIME parsing is pure Swift, and rendering uses WebKit with the AppKit print system.

```sh
eml2pdf message.eml                         # → message.pdf next to the input
eml2pdf -o ~/Desktop/out.pdf message.eml
eml2pdf first.eml reply.eml reply2.eml      # → first-thread.pdf: one PDF for the whole chain, in this order
```

## What's in the PDF

- **A header card** with Subject, From, Sender, To, Cc, Bcc, Reply-To and Date (in your local time zone).
- **An attachment list** of every attachment, with its name, MIME type and size, including files that can't be shown (PDF, zip, etc.).
- **The body.** HTML bodies keep their own styling, scoped so it can't break the header. Wide layouts are scaled down to fit the page width. Plain-text bodies are wrapped, links are clickable, and quoted lines are greyed.
- **Images.** Inline `cid:` images appear where the sender placed them. Image attachments appear in an "Images" gallery after the body.
- **Forwarded messages** attached as `message/rfc822` are shown in full, nested under the message that carried them.
- **Footer** on every page with the subject and "Page n of N".

### Email chains

Passing several files produces one document, with the messages kept in the order you passed them:

- a cover page with the thread subject (`Re:`/`Fwd:` stripped), the date range, and every participant;
- a clickable index of the messages;
- each message starting on a new page, labelled "Message n of N".

If any input fails to parse, no PDF is written.

## Options

| Option | |
|---|---|
| `-o, --output <path>` | output file (default: next to the first input) |
| `--paper a4\|letter` | paper size (default: from your locale) |
| `--remote-images` | load remote images and stylesheets. By default all `http(s)` loads are blocked, which keeps tracking pixels out and makes output repeatable. |
| `--html` | write the intermediate HTML instead (for debugging) |
| `-f, --force` | overwrite an existing output file |

## Build & install

Requires macOS 13+ and the Xcode Command Line Tools.

```sh
make            # builds .build/eml2pdf
make test       # parser, HTML and end-to-end PDF checks against Tests/Fixtures
make install    # copies to /usr/local/bin (PREFIX=... to change)
```

The project builds with `swiftc` through `make`, not SwiftPM. Some Command Line Tools installs have a broken SwiftPM manifest library and a stale
`usr/include/swift/module.modulemap`, which causes `redefinition of module 'SwiftBridging'`.
The Makefile works around the stale modulemap with a VFS overlay. To fix it permanently, run
`sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap`,
or reinstall the Command Line Tools.

`Tests/make_fixtures.py` regenerates the fixture emails (Python stdlib only).
