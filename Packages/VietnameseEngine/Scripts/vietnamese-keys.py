#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Corpus authoring helper: prints the Telex and VNI keystrokes that type Vietnamese text in the canonical
order of spec/01-engine.md ENG-T02 O1 (each modifier key right after the letter it modifies, the `w` /
`7` of `ươ` after the `o`, the stroke key right after `d`, the tone key at the end of the word).

It reads one text per line on standard input and writes `text<TAB>telex<TAB>vni`. It is independent of the
engine (Unicode decomposition only). The output is a starting point for hand-curated corpus rows: words
whose Telex spelling contains a transform letter where the name has a plain letter (`Kar`) still need an
escape added by hand (`Karr`).

Usage: python3 -I Scripts/vietnamese-keys.py < names.txt
"""

import sys
import unicodedata

TONES = {"\u0301": ("s", "1"), "\u0300": ("f", "2"), "\u0309": ("r", "3"), "\u0303": ("x", "4"), "\u0323": ("j", "5")}
MODIFIERS = {"\u0302": "circumflex", "\u0306": "breve", "\u031b": "horn"}
HORN = "\u031b"


def letter_keys(character):
    """(telex, vni, tone) for one letter; tone is a TONES key or None."""
    if character in "đĐ":
        base = "d" if character == "đ" else "D"
        return base + base, base + "9", None
    decomposed = unicodedata.normalize("NFD", character)
    base, marks = decomposed[0], decomposed[1:]
    telex, vni, tone = base, base, None
    for mark in marks:
        if mark in TONES:
            tone = mark
        elif MODIFIERS.get(mark) == "circumflex":
            telex += base
            vni += "6"
        elif MODIFIERS.get(mark) == "breve":
            telex += "w"
            vni += "8"
        elif MODIFIERS.get(mark) == "horn":
            telex += "w"
            vni += "7"
    return telex, vni, tone


def word_keys(word):
    telex, vni, tone = "", "", None
    letters = list(word)
    index = 0
    while index < len(letters):
        character = letters[index]
        # `ươ`: type u o, then one w (7) after the o.
        if character.lower() == "ư" and index + 1 < len(letters) and unicodedata.normalize("NFD", letters[index + 1])[0].lower() == "o" \
                and HORN in unicodedata.normalize("NFD", letters[index + 1]):
            u_telex, u_vni, u_tone = letter_keys(character)
            o_telex, o_vni, o_tone = letter_keys(letters[index + 1])
            telex += u_telex[0] + o_telex
            vni += u_vni[0] + o_vni
            tone = u_tone or o_tone or tone
            index += 2
            continue
        part_telex, part_vni, part_tone = letter_keys(character)
        telex += part_telex
        vni += part_vni
        tone = part_tone or tone
        index += 1
    if tone:
        telex += TONES[tone][0]
        vni += TONES[tone][1]
    return telex, vni


def text_keys(text):
    telex, vni = [], []
    word = ""
    for character in text + " ":
        if unicodedata.category(character).startswith("L"):
            word += character
            continue
        if word:
            parts = word_keys(word)
            telex.append(parts[0])
            vni.append(parts[1])
            word = ""
        if character != " " or len(telex) > 0:
            telex.append(character)
            vni.append(character)
    return "".join(telex).rstrip(" "), "".join(vni).rstrip(" ")


def main():
    for line in sys.stdin:
        text = unicodedata.normalize("NFC", line.rstrip("\n"))
        if not text:
            continue
        telex, vni = text_keys(text)
        print(f"{text}\t{telex}\t{vni}")


if __name__ == "__main__":
    main()
