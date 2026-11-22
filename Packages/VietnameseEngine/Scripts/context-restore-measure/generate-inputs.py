#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: MPL-2.0
"""Writes the input sets of the context restore measurement (README.md in this directory) into OUT_DIR: one key
sequence per line in the notation of KeyNotation (`⌫` Backspace, `⎋` the restore key) and of this harness (`↵`
Return, `⇥` Tab).

    python3 -I generate-inputs.py OUT_DIR [--seed N] [--mixed N]

Sets:
  f_fuzz     the random sequences of ../w-doubling-measure/generate-inputs.py with its defaults (seed 22112026,
             100,000 lines), written by that script's own function, byte for byte
  g_mixed    lines that mix English words of the bundled lexicon, the raw keys of the ambiguity table (the words
             valid in both languages) and Telex keyings of Vietnamese syllables, with spaces, punctuation, Return,
             Tab and non-ASCII boundaries between them, and the restore key (sometimes twice, or after a Backspace)
             right after commits
  h_phrases  every bundled phrase typed from an empty field, after an English word and after a Vietnamese word,
             then a space and the restore key, and once more followed by a Vietnamese word

The defaults reproduce the sets of 23/11/2026: seed 23112026, 60,000 mixed lines, the bundled data of this checkout
(identical at 28dbd6d0 and at the head of REG-42). Standard library only.
"""
import argparse
import importlib.util
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(PACKAGE, "Sources", "VietnameseEngineData", "Resources")
W_DOUBLING = os.path.join(os.path.dirname(HERE), "w-doubling-measure", "generate-inputs.py")
SEED = 23112026
MIXED_COUNT = 60_000
TOGGLE = "⎋"
BACKSPACE = "⌫"
RETURN = "↵"
TAB = "⇥"
# Boundaries between tokens and their weights: a space mostly, prose punctuation, the hard boundaries Return and Tab,
# and non-ASCII characters (ellipsis, curly quote, no-break space), after which ENG-R706 passes through.
BOUNDARIES = [" "] * 30 + [", ", ". ", "? ", "! ", "; ", ": ", ") "] + [RETURN, TAB] + ["\u2026", "\u201d", "\u00a0"]
# What may follow a boundary: the restore key, twice, after a Backspace, or nothing.
AFTER_BOUNDARY = [TOGGLE] * 7 + [TOGGLE + TOGGLE] + [BACKSPACE + TOGGLE] + [""] * 11


def read_list(name):
    with open(os.path.join(RESOURCES, name), encoding="utf-8") as handle:
        return [line for line in handle.read().split("\n") if line and not line.startswith("#")]


def ambiguity_raws():
    rows = read_list("ambiguity.tsv")
    return [row.split("\t")[0] for row in rows[1:] if row.split("\t")[0].isalpha()]


def w_doubling_fuzz():
    """The f_fuzz set of the w doubling harness, from its own module."""
    spec = importlib.util.spec_from_file_location("w_doubling_generate_inputs", W_DOUBLING)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.fuzz(module.SEED, module.FUZZ_COUNT)


def cased(word, rng):
    """Lowercase mostly, sometimes in sentence case."""
    return word[0].upper() + word[1:] if rng.random() < 0.15 else word


def mixed_line(rng, english, collisions, vietnamese):
    tokens = rng.randint(2, 9)
    pieces = []
    for index in range(tokens):
        kind = rng.random()
        if kind < 0.35:
            word = rng.choice(english)
        elif kind < 0.65:
            word = rng.choice(collisions)
        else:
            word = rng.choice(vietnamese)
        pieces.append(cased(word, rng) if index == 0 else word)
        pieces.append(rng.choice(BOUNDARIES) if index < tokens - 1 else rng.choice([" ", ". ", ", ", RETURN]))
        pieces.append(rng.choice(AFTER_BOUNDARY))
    return "".join(pieces)


def mixed(seed, count):
    rng = random.Random(seed)
    english = [word for word in read_list("english.txt") if word.isalpha()]
    collisions = ambiguity_raws()
    vietnamese = read_list("vietnamese-keyings.txt")
    return [mixed_line(rng, english, collisions, vietnamese) for _ in range(count)]


def phrases():
    lines = []
    for phrase in read_list("phrases.txt"):
        lines.append(phrase + " " + TOGGLE)
        lines.append("and " + phrase + " " + TOGGLE)
        lines.append("vieejt " + phrase + " " + TOGGLE)
        lines.append(phrase + " " + "nhaf ")
    return lines


def write(directory, name, lines):
    with open(os.path.join(directory, name + ".txt"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write("".join(line + "\n" for line in lines))
    print(f"{name}.txt {len(lines)}")


def main(argv):
    parser = argparse.ArgumentParser(description="Writes the input sets of the context restore measurement.")
    parser.add_argument("out", metavar="OUT_DIR", help="directory for the .txt input sets (created if missing)")
    parser.add_argument("--seed", type=int, default=SEED, help=f"seed of the mixed lines (default {SEED})")
    parser.add_argument("--mixed", type=int, default=MIXED_COUNT, help=f"mixed lines (default {MIXED_COUNT})")
    args = parser.parse_args(argv)
    try:
        sets = {"f_fuzz": w_doubling_fuzz(), "g_mixed": mixed(args.seed, args.mixed), "h_phrases": phrases()}
    except OSError as error:
        print(f"generate-inputs: {error}", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    for name, lines in sets.items():
        write(args.out, name, lines)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
