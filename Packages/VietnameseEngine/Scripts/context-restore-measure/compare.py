#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: MPL-2.0
"""Compares the outputs of run-tree.sh for two trees (base and head) and prints the figures that spec/01-engine.md
ENG-R706 (REG-42) and ADR 0010 item 9 quote (README.md in this directory).

    python3 -I compare.py --inputs DIR --out DIR [--base LABEL] [--head LABEL] [--examples N]

For every set and both typoCorrection runs it counts the lines whose final field or event hash differs between the
trees, and the lines the harness flagged (a restore key right after a commit that ENG-R706 covers). Up to the first
flagged restore key both trees see the same events, so a line differs exactly when it is flagged. Exit status 1 when
an output has a different number of lines than its input, when a line differs without the flag, when a flagged line
does not differ, or when the two trees disagree on whether a line is flagged. Standard library only.
"""
import argparse
import os
import sys


class Mismatch(Exception):
    pass


def read_lines(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().split("\n")[:-1]


def rows(path):
    result = []
    for line in read_lines(path):
        flag, field, digest = line.split("\t")
        result.append((int(flag), field, digest))
    return result


def compare(keys, base, head, examples):
    """The figures of one set and one run, and up to `examples` differing lines."""
    if not len(keys) == len(base) == len(head):
        raise Mismatch(f"{len(keys)} inputs, {len(base)} base rows, {len(head)} head rows")
    figures = {"lines": len(keys), "flagged": 0, "toggles": 0, "differ": 0, "final": 0, "unflagged": 0,
               "unchanged": 0, "disagree": 0}
    shown = []
    for key, (base_flag, base_field, base_hash), (head_flag, head_field, head_hash) in zip(keys, base, head):
        flagged = base_flag > 0
        differs = base_hash != head_hash or base_field != head_field
        figures["flagged"] += flagged
        figures["toggles"] += base_flag
        figures["differ"] += differs
        figures["final"] += base_field != head_field
        figures["unflagged"] += differs and not flagged
        figures["unchanged"] += flagged and not differs
        figures["disagree"] += flagged != (head_flag > 0)
        if differs and len(shown) < examples:
            shown.append((key, base_field, head_field))
    return figures, shown


def count(number):
    return f"{number:,}"


def main(argv):
    parser = argparse.ArgumentParser(description="Compares the context restore measurement of two trees.")
    parser.add_argument("--inputs", required=True, help="directory written by generate-inputs.py")
    parser.add_argument("--out", required=True, help="directory written by run-tree.sh")
    parser.add_argument("--base", default="base", help="label of the base tree (default base)")
    parser.add_argument("--head", default="head", help="label of the head tree (default head)")
    parser.add_argument("--examples", type=int, default=3, help="differing lines shown per set and run (default 3)")
    args = parser.parse_args(argv)
    names = sorted(name[:-4] for name in os.listdir(args.inputs) if name.endswith(".txt"))
    failed = False
    print("set        run  lines    flagged  restore keys flagged  differ (final field)  differ unflagged  "
          "flagged unchanged  trees disagree on the flag")
    for name in names:
        for correction in (0, 1):
            paths = [os.path.join(args.out, f"{label}-{name}-c{correction}.tsv") for label in (args.base, args.head)]
            missing = [path for path in paths if not os.path.isfile(path)]
            if missing:
                print(f"{name:<10} c{correction}  skipped, missing {', '.join(missing)}")
                continue
            keys = read_lines(os.path.join(args.inputs, name + ".txt"))
            try:
                figures, shown = compare(keys, rows(paths[0]), rows(paths[1]), args.examples)
            except Mismatch as error:
                print(f"{name:<10} c{correction}  {error}")
                failed = True
                continue
            print(f"{name:<10} c{correction}  {count(figures['lines']):>8} {count(figures['flagged']):>8}  "
                  f"{count(figures['toggles']):>20}  {count(figures['differ']):>6} ({count(figures['final'])})"
                  f"{'':>11}{count(figures['unflagged']):>6}{'':>12}{count(figures['unchanged']):>7}"
                  f"{'':>20}{count(figures['disagree']):>7}")
            for key, base_field, head_field in shown:
                print(f"    {key!r}\n      base {base_field!r}\n      head {head_field!r}")
            failed = failed or figures["unflagged"] > 0 or figures["unchanged"] > 0 or figures["disagree"] > 0
    print("result: " + ("FAIL, see the columns above" if failed else
                        "every differing line is a restore key right after a commit ENG-R706 covers, and every "
                        "such line differs"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
