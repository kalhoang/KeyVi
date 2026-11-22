#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: MPL-2.0
"""Writes the input sets of the w doubling measurement (README.md in this directory) into OUT_DIR: one key sequence
per line in the notation of KeyNotation (`⌫` Backspace, `⎋` the restore key), every word followed by a space.

    python3 -I generate-inputs.py OUT_DIR [--dictionary FILE] [--lexicon FILE] [--seed N] [--fuzz N]

The defaults reproduce the sets of 22/11/2026: the macOS word list, the bundled lexicon of this checkout (identical at
0fdb9d98 and d0941160), seed 22112026 and 100,000 random sequences. Standard library only.
"""
import argparse
import os
import random
import sys

PACKAGE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LEXICON = os.path.join(PACKAGE, "Sources", "VietnameseEngineData", "Resources", "english.txt")
DICTIONARY = "/usr/share/dict/words"
SEED = 22112026
FUZZ_COUNT = 100_000
# The fuzz alphabet around w and W: vowels, tone keys, a few consonants, Backspace, space and the restore key. The
# order and the weights decide the sequences a seed gives; changing them changes every figure of set f_fuzz.
FUZZ_ALPHABET = (["w"] * 6 + ["W"] * 6 + list("aeiouy") * 2 + list("AEOU") + list("sfrxjz") * 2 + list("tdnhcg")
                 + ["⌫"] * 3 + [" "] * 2 + ["⎋"])
FUZZ_LENGTH = (2, 14)


def read_words(path):
    with open(path, encoding="utf-8") as handle:
        return [word for word in handle.read().split("\n") if word]


def write(directory, name, lines):
    with open(os.path.join(directory, name + ".txt"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write("".join(line + "\n" for line in lines))
    print(f"{name}.txt {len(lines)}")


def habit(word):
    """The habit of input methods where `w` alone gives `ư` (REG-40, REG-41): the first `w` typed twice."""
    return ("ww" if word[0] == "w" else "Ww") + word[1:]


def word_sets(words, lexicon):
    """The word sets by name, each a list of key sequences without the trailing space."""
    starts = [word for word in words if word[0] in "wW"]
    with_ww = [word for word in words if "ww" in word]
    inner = [word for word in lexicon if "w" in word and not word.startswith("w")]
    return {
        "a_dict": words,
        "b_habit": [habit(word) for word in starts],
        "b_written": starts,
        "c_capital": [word for word in starts if word[0] == "W"],
        "d_ww_written": with_ww,
        "d_ww_doubled": [word.replace("w", "ww").replace("W", "WW") for word in with_ww],
        "d_lexicon_doubled": [word.replace("w", "ww") for word in inner],
        "d_lexicon_written": inner,
        "e_capital_inner": [word[0].upper() + word[1:].replace("w", "Ww") for word in inner],
    }


def fuzz(seed, count):
    rng = random.Random(seed)
    low, high = FUZZ_LENGTH
    return ["".join(rng.choice(FUZZ_ALPHABET) for _ in range(rng.randint(low, high))) for _ in range(count)]


def main(argv):
    parser = argparse.ArgumentParser(description="Writes the input sets of the w doubling measurement.")
    parser.add_argument("out", metavar="OUT_DIR", help="directory for the .txt input sets (created if missing)")
    parser.add_argument("--dictionary", default=DICTIONARY, help=f"English word list (default {DICTIONARY})")
    parser.add_argument("--lexicon", default=LEXICON, help="bundled lexicon (default: english.txt of this package)")
    parser.add_argument("--seed", type=int, default=SEED, help=f"seed of the random sequences (default {SEED})")
    parser.add_argument("--fuzz", type=int, default=FUZZ_COUNT, help=f"random sequences (default {FUZZ_COUNT})")
    args = parser.parse_args(argv)
    try:
        words, lexicon = read_words(args.dictionary), read_words(args.lexicon)
    except OSError as error:
        print(f"generate-inputs: {error}", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    for name, lines in word_sets(words, lexicon).items():
        write(args.out, name, [line + " " for line in lines])
    write(args.out, "f_fuzz", fuzz(args.seed, args.fuzz))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
