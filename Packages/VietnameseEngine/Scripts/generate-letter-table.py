# SPDX-License-Identifier: MPL-2.0
"""Generate Sources/VietnameseEngine/Generated/LetterTable.swift (ENG-R301).

The table lists the 146 letters the engine can emit: the 12 Vietnamese vowel letters
(a ă â e ê i o ô ơ u ư y) with each of the 6 tones in both cases, plus đ and Đ. Every entry is
derived from Unicode character data only (canonical composition of a base letter with combining
marks, and the character name of the d with stroke), then ordered by code point.

Usage (from any directory):
    python3 -I Scripts/generate-letter-table.py           # write the Swift file
    python3 -I Scripts/generate-letter-table.py --check   # exit 1 if the committed file differs
"""
import sys
import unicodedata
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parent.parent
OUTPUT = PACKAGE_DIR / "Sources" / "VietnameseEngine" / "Generated" / "LetterTable.swift"

# (base letter, modifier name, combining mark or None)
VOWELS = [
    ("a", "none", None),
    ("a", "breve", "\u0306"),
    ("a", "circumflex", "\u0302"),
    ("e", "none", None),
    ("e", "circumflex", "\u0302"),
    ("i", "none", None),
    ("o", "none", None),
    ("o", "circumflex", "\u0302"),
    ("o", "horn", "\u031b"),
    ("u", "none", None),
    ("u", "horn", "\u031b"),
    ("y", "none", None),
]

# Tones in the order of spec/01-engine.md 3.2 (0 = ngang ... 5 = nặng) and Swift `Tone` case names.
TONES = [
    ("level", None),
    ("acute", "\u0301"),
    ("grave", "\u0300"),
    ("hook", "\u0309"),
    ("tilde", "\u0303"),
    ("dot", "\u0323"),
]


def compose(text):
    composed = unicodedata.normalize("NFC", text)
    if len(composed) != 1:
        raise SystemExit(f"no precomposed code point for {text!r} -> {composed!r}")
    return composed


def entries():
    rows = []
    for base, modifier, modifier_mark in VOWELS:
        for tone, tone_mark in TONES:
            for upper in (False, True):
                text = base.upper() if upper else base
                if modifier_mark:
                    text += modifier_mark
                if tone_mark:
                    text += tone_mark
                char = compose(text)
                rows.append((ord(char), base, modifier, tone, upper))
    for upper, name in ((False, "LATIN SMALL LETTER D WITH STROKE"), (True, "LATIN CAPITAL LETTER D WITH STROKE")):
        rows.append((ord(unicodedata.lookup(name)), "d", "stroke", "level", upper))
    rows.sort(key=lambda row: row[0])
    if len(rows) != 146 or len({row[0] for row in rows}) != 146:
        raise SystemExit(f"expected 146 distinct letters, got {len(rows)}")
    return rows


def render():
    lines = [
        "// SPDX-License-Identifier: MPL-2.0",
        "//",
        "// GENERATED FILE, DO NOT EDIT. Regenerate with `python3 -I Scripts/generate-letter-table.py`.",
        "// Source: Unicode character data only (canonical composition and character names), ENG-R301.",
        "// The 146 letters the engine can emit, ordered by code point.",
        "",
        "extension LetterTable {",
        "    package static let entries: [LetterTableEntry] = [",
    ]
    for scalar, base, modifier, tone, upper in entries():
        lines.append(f"        // {unicodedata.name(chr(scalar))}")
        lines.append(
            f'        LetterTableEntry(0x{scalar:04X}, "{base}", .{modifier}, .{tone}, uppercase: {"true" if upper else "false"}),'
        )
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main(argv):
    text = render()
    if "--check" in argv:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != text:
            print(f"{OUTPUT} is out of date; run Scripts/generate-letter-table.py", file=sys.stderr)
            return 1
        print("LetterTable.swift is up to date (146 letters)")
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUTPUT} (146 letters, Unicode {unicodedata.unidata_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
