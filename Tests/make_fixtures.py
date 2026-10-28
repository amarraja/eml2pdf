#!/usr/bin/env python3
"""Regenerates the .eml fixtures in Tests/Fixtures using only the Python stdlib."""
import struct
import zlib
from email.message import EmailMessage
from email.headerregistry import Address
from email import policy
from pathlib import Path

OUT = Path(__file__).parent / "Fixtures"


def png(width, height, rgb_fn):
    raw = b"".join(
        b"\x00" + b"".join(bytes(rgb_fn(x, y)) for x in range(width)) for y in range(height)
    )

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


LOGO = png(160, 48, lambda x, y: (30, 90 + y, 200 - x // 2))
PHOTO = png(480, 320, lambda x, y: (x * 255 // 480, y * 255 // 320, 160))
FAKE_PDF = b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"


def write(name, msg):
    (OUT / name).write_bytes(msg.as_bytes(policy=policy.SMTP))


def rich():
    m = EmailMessage()
    m["Subject"] = "Q3 roadmap — résumé & next steps ✅"
    m["From"] = Address("Zoë Alvarez", addr_spec="zoe@example.com")
    m["To"] = [Address("Bob Smith", addr_spec="bob@example.com"), Address("", addr_spec="carol@example.org")]
    m["Cc"] = Address("Dana Øberg", addr_spec="dana@example.net")
    m["Bcc"] = Address("", addr_spec="secret-archive@example.com")
    m["Reply-To"] = Address("Roadmap list", addr_spec="roadmap@example.com")
    m["Date"] = "Tue, 14 Oct 2025 09:15:00 +0100"
    m["Message-ID"] = "<rich-1@example.com>"
    m.set_content("Hi all,\n\nPlain text fallback. See https://example.com/roadmap.\n\n> quoted line\n")
    m.add_alternative(
        """<!doctype html><html><head><meta charset="utf-8"><title>x</title>
<style>body { font-family: Georgia; } .note { color: #a33; }</style>
<script>alert('nope')</script></head>
<body onload="evil()"><p>Hi all,</p><p class="note">Here is the <b>HTML</b> body with an inline logo:</p>
<p><img src="cid:logo@example.com" alt="logo"></p>
<table width="900" style="width:900px;border:1px solid #ccc"><tr><td>A deliberately wide table that should be shrunk to fit the page width rather than clipped off the right-hand edge.</td></tr></table>
<p><img src="https://tracker.example.com/pixel.gif" width="1" height="1"></p>
<p><a href="javascript:alert(1)">bad link</a></p></body></html>""",
        subtype="html",
    )
    m.get_payload()[1].add_related(LOGO, "image", "png", cid="<logo@example.com>", filename="logo.png")
    m.add_attachment(PHOTO, maintype="image", subtype="png", filename="Ünïcode photo.png")
    m.add_attachment(FAKE_PDF, maintype="application", subtype="pdf", filename="Q3 Roadmap.pdf")
    m.add_attachment(b"PK\x03\x04zip", maintype="application", subtype="zip", filename="archive.zip")
    write("rich.eml", m)


def latin1_reply():
    m = EmailMessage()
    m["Subject"] = "Re: Q3 roadmap — résumé & next steps ✅"
    m["From"] = Address("Bob Smith", addr_spec="bob@example.com")
    m["To"] = Address("Zoë Alvarez", addr_spec="zoe@example.com")
    m["Cc"] = [Address("", addr_spec="carol@example.org"), Address("Dana Øberg", addr_spec="dana@example.net")]
    m["Date"] = "Tue, 14 Oct 2025 11:02:00 -0400"
    m.set_content("Merci beaucoup, ça marche.\n\nCafé at 3?\n\n> Hi all,\n> Plain text fallback.\n",
                  charset="iso-8859-1", cte="quoted-printable")
    # Same Content-ID as rich.eml but a different image, to prove cid lookups are per message.
    m.add_attachment(png(40, 40, lambda x, y: (220, 40, 40)), maintype="image", subtype="png",
                     cid="<logo@example.com>", filename="red-square.png")
    write("reply.eml", m)


def forward():
    inner = EmailMessage()
    inner["Subject"] = "Original vendor quote"
    inner["From"] = Address("Vendor", addr_spec="sales@vendor.example")
    inner["To"] = Address("Zoë Alvarez", addr_spec="zoe@example.com")
    inner["Date"] = "Mon, 13 Oct 2025 16:40:00 +0000"
    inner.set_content("Quote attached. Total: 1,200 EUR.")
    inner.add_attachment(FAKE_PDF, maintype="application", subtype="pdf", filename="quote-4471.pdf")

    m = EmailMessage()
    m["Subject"] = "Fwd: Original vendor quote"
    m["From"] = Address("Zoë Alvarez", addr_spec="zoe@example.com")
    m["To"] = Address("Bob Smith", addr_spec="bob@example.com")
    m["Date"] = "Wed, 15 Oct 2025 08:00:00 +0100"
    m.set_content("FYI — forwarding the vendor quote.")
    m.add_attachment(inner)
    write("forward.eml", m)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    rich()
    latin1_reply()
    forward()
    print("fixtures written to", OUT)
