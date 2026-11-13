# SPDX-License-Identifier: GPL-3.0-or-later
# Provenance of SpikeIMK/Resources/SpikeIMK.tiff (CLR-R7): original pixel art drawn by this script.
# Usage: python3 -I SpikeIMK/Tools/make-icon.py /tmp/s16.png /tmp/s32.png && tiffutil -cathidpicheck /tmp/s16.png /tmp/s32.png -out SpikeIMK/Resources/SpikeIMK.tiff
# Writes a 16x16 and 32x32 monochrome PNG pair: a rounded square outline with an "S1" mark (spike S1).
import struct, sys, zlib

def png(size, pixels, path):
    raw = b"".join(b"\x00" + bytes(sum(([0, 0, 0, a] for a in row), [])) for row in pixels)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

GLYPH = [
    "................",
    "..############..",
    ".#............#.",
    ".#............#.",
    ".#..###....#..#.",
    ".#.#......##..#.",
    ".#.#.......#..#.",
    ".#..##.....#..#.",
    ".#....#....#..#.",
    ".#....#....#..#.",
    ".#.###....###.#.",
    ".#............#.",
    ".#............#.",
    ".#............#.",
    "..############..",
    "................",
]

def scaled(factor):
    rows = []
    for line in GLYPH:
        row = [255 if ch == "#" else 0 for ch in line for _ in range(factor)]
        rows.extend([row] * factor)
    return rows

png(16, scaled(1), sys.argv[1])
png(32, scaled(2), sys.argv[2])
