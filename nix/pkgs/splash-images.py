"""Draw the two images the boot splash is made of.

The mark is the one already in assets/web/favicon.svg -- three bars, two lines
of a hymn and a third being written -- on the same 32-unit grid, scaled up so
it is crisp on a 1080p panel and cropped to the bars themselves, so the script
can centre it without counting empty pixels.

The colours are PagePalette.dark from lib/src/ui/page_style.dart, not the web
interface's skin: two colours plus one muted tone, no accent. The panel is the
product, and it should look like one product from the moment it lights up.

Generated rather than committed, so the geometry stays a handful of numbers
somebody can change, and the tree carries no binary whose provenance nobody
remembers.
"""

import struct
import sys
import zlib

UNIT = 40  # Pixels per grid unit: room to be scaled down onto any panel.
SAMPLES = 4  # Supersampling, so the round caps do not stair-step.

FOREGROUND = (0xF4, 0xF4, 0xF4)
MUTED = (0x8C, 0x8C, 0x8C)


def capsule(width, height, colour):
    """A bar with round caps, as RGBA rows.

    The radius is half the height, which is what the favicon's rx amounts to
    once the bars are this thick.
    """
    red, green, blue = colour
    radius = height / 2
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            covered = 0
            for sy in range(SAMPLES):
                py = y + (sy + 0.5) / SAMPLES
                for sx in range(SAMPLES):
                    px = x + (sx + 0.5) / SAMPLES
                    # Nearest point on the capsule's spine, then the distance
                    # to it: inside means within one radius of the spine.
                    spine = min(max(px, radius), width - radius)
                    dx = px - spine
                    dy = py - radius
                    if dx * dx + dy * dy <= radius * radius:
                        covered += 1
            alpha = round(255 * covered / (SAMPLES * SAMPLES))
            row += bytes((red, green, blue, alpha))
        rows.append(bytes(row))
    return rows


def blank(width, height):
    return [bytes(width * 4) for _ in range(height)]


def paste(canvas, rows, top):
    for offset, row in enumerate(rows):
        canvas[top + offset] = row


def png(rows):
    """The smallest PNG that says what these images need to say: 8-bit RGBA."""
    height = len(rows)
    width = len(rows[0]) // 4
    raw = b"".join(b"\0" + row for row in rows)

    def chunk(tag, data):
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\x0a"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main(directory):
    long_bar = 18 * UNIT
    short_bar = 11 * UNIT
    thickness = 3 * UNIT
    stride = 7 * UNIT  # Gap between bar tops, as in the favicon.

    # The mark is the two settled lines; the third is animated on top of it,
    # so it is left out here and the canvas simply keeps its row.
    mark = blank(long_bar, 2 * stride + thickness)
    paste(mark, capsule(long_bar, thickness, FOREGROUND), 0)
    paste(mark, capsule(long_bar, thickness, FOREGROUND), stride)

    with open(directory + "/mark.png", "wb") as handle:
        handle.write(png(mark))
    with open(directory + "/line.png", "wb") as handle:
        handle.write(png(capsule(short_bar, thickness, MUTED)))


if __name__ == "__main__":
    main(sys.argv[1])
