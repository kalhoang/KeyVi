#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: MPL-2.0
"""Compares the outputs of run-tree.sh for two trees (base and head) and prints the figures that spec/01-engine.md
ENG-R804 (the amendment of 22/11/2026), REG-41 and ADR 0010 item 8 quote (README.md in this directory).

    python3 -I compare.py --inputs DIR --out DIR [--base LABEL] [--head LABEL]

A set whose input or outputs are missing is reported and skipped. Exit status 1 when an output has a different number
of lines than its input, or when a random sequence differs between the trees without the flag of the harness (a
difference that the REG-41 change does not explain). Standard library only.
"""
import argparse
import os
import sys

# Sets typed as written or with every w doubled: REG-41 changes none of their commits.
UNCHANGED_SETS = ("a_dict", "d_ww_written", "d_ww_doubled", "d_lexicon_written", "d_lexicon_doubled", "b_written",
                  "c_capital")


class LengthMismatch(Exception):
    pass


def read_lines(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().split("\n")[:-1]


class Outputs:
    def __init__(self, inputs, out, base, head):
        self.inputs, self.out, self.labels = inputs, out, {"base": base, "head": head}

    def keys(self, name):
        return read_lines(os.path.join(self.inputs, name + ".txt"))

    def rows(self, tree, name, correction):
        path = os.path.join(self.out, f"{self.labels[tree]}-{name}-c{correction}.tsv")
        return [line.split("\t") for line in read_lines(path)]

    def available(self, name, correction):
        paths = [os.path.join(self.inputs, name + ".txt")] + [
            os.path.join(self.out, f"{label}-{name}-c{correction}.tsv") for label in self.labels.values()]
        missing = [path for path in paths if not os.path.isfile(path)]
        if missing:
            print(f"  {name}: skipped, missing {', '.join(missing)}")
        return not missing

    def load(self, name, correction):
        """The keys, the base rows and the head rows of one set, checked for equal length."""
        keys, base, head = self.keys(name), self.rows("base", name, correction), self.rows("head", name, correction)
        if not len(keys) == len(base) == len(head):
            raise LengthMismatch(f"{name} c{correction}: {len(keys)} inputs, {len(base)} base rows, {len(head)} head")
        return keys, base, head


def count(number):
    return f"{number:,}"


def unchanged_sets(outputs, correction):
    print("Typed as written or with every w doubled, the same text in base and head:")
    for name in UNCHANGED_SETS:
        if not outputs.available(name, correction):
            continue
        keys, base, head = outputs.load(name, correction)
        differ = [(keys[i], base[i][1], head[i][1]) for i in range(len(keys)) if base[i][1] != head[i][1]]
        sample = f" {differ[:5]}" if differ else ""
        print(f"  {name:<18} {count(len(keys)):>8} inputs, {count(len(differ))} differ{sample}")
    if outputs.available("d_lexicon_doubled", correction):
        keys, base, head = outputs.load("d_lexicon_doubled", correction)
        words = read_lines(os.path.join(outputs.inputs, "d_lexicon_written.txt"))
        committed = {tree: sum(1 for i, word in enumerate(words) if rows[i][1] == word)
                     for tree, rows in (("base", base), ("head", head))}
        print(f"  d_lexicon_doubled: {count(committed['base'])} of {count(len(words))} commit the word in base,"
              f" {count(committed['head'])} in head")


def habit(outputs, correction):
    if not (outputs.available("b_habit", correction) and outputs.available("b_written", correction)):
        return
    _, habit_base, habit_head = outputs.load("b_habit", correction)
    keys, written_base, written_head = outputs.load("b_written", correction)
    if len(keys) != len(habit_base):
        raise LengthMismatch(f"b_habit has {len(habit_base)} rows, b_written {len(keys)}")
    words = [key[:-1] for key in keys]
    capitalised = sum(1 for word in words if word[0] == "W")
    print(f"Habit, w -> ww and W -> Ww (b_habit): {count(len(words))} words that start with w or W,"
          f" {count(capitalised)} capitalised")
    results = {}
    for tree, habit_rows, written_rows in (("base", habit_base, written_base), ("head", habit_head, written_head)):
        results[tree] = [row[1] for row in habit_rows]
        other = [i for i, word in enumerate(words) if habit_rows[i][1] != word + " "]
        lowercase = [i for i in other if words[i][0] == "W" and habit_rows[i][1] == "w" + words[i][1:] + " "]
        as_one_w = [i for i in other if habit_rows[i][1] == written_rows[i][1]]
        print(f"  {tree}: {count(len(words) - len(other))} commit the word; of the other {count(len(other))},"
              f" {count(len(lowercase))} are capitalised words committed in lowercase and {count(len(as_one_w))}"
              f" commit what the word typed with one w commits {[(words[i], habit_rows[i][1]) for i in other][:6]}")
    changed = [i for i in range(len(words)) if results["base"][i] != results["head"][i]]
    capital = [i for i in changed if words[i][0] == "W"]
    print(f"  base -> head: {count(len(changed))} commits change, {count(len(capital))} of them capitalised words,"
          f" {count(len(changed) - len(capital))} start with a lowercase w"
          f" {[(words[i], results['base'][i], results['head'][i]) for i in changed][:6]}")


def capital_inner(outputs, correction):
    """Set e_capital_inner: the differences, and how many differ only in the case of a w that is the second letter."""
    if not outputs.available("e_capital_inner", correction):
        return
    keys, base, head = outputs.load("e_capital_inner", correction)
    differ = [i for i in range(len(keys)) if base[i][1] != head[i][1]]

    def second_letter_case_only(i):
        before, after = base[i][1], head[i][1]
        positions = [p for p in range(len(before)) if before[p] != after[p]] if len(before) == len(after) else None
        return positions == [1] and before.lower() == after.lower() and keys[i][1] == "W"

    shaped = [i for i in differ if second_letter_case_only(i)]
    print(f"Capital first letter, every w as Ww (e_capital_inner): {count(len(keys))} lexicon words,"
          f" {count(len(differ))} differ, {count(len(shaped))} of them with the w second and only in its case"
          f" {[(keys[i], base[i][1], head[i][1]) for i in differ][:6]}")


def random_sequences(outputs, correction):
    """Set f_fuzz: every difference after some event must carry the harness flag in head."""
    if not outputs.available("f_fuzz", correction):
        return 0
    keys, base, head = outputs.load("f_fuzz", correction)
    differ = [i for i in range(len(keys)) if base[i][1:] != head[i][1:]]
    unflagged = [i for i in differ if head[i][0] != "1"]
    flagged = sum(1 for row in head if row[0] == "1")
    final = sum(1 for i in range(len(keys)) if base[i][1] != head[i][1])
    print(f"Random sequences (f_fuzz): {count(len(keys))} sequences, {count(flagged)} flagged in head (a capital W, then"
          f" a lowercase w escaping its standalone u-horn); {count(len(differ))} differ after some event"
          f" ({count(final)} in the final field), {count(len(differ) - len(unflagged))} of them flagged,"
          f" {count(len(unflagged))} not flagged")
    for i in unflagged[:20]:
        print(f"  not flagged: {keys[i]!r} base {base[i][1]!r} head {head[i][1]!r}")
    return len(unflagged)


def main(argv):
    parser = argparse.ArgumentParser(description="Compares the w doubling measurement outputs of two trees.")
    parser.add_argument("--inputs", required=True, help="directory written by generate-inputs.py")
    parser.add_argument("--out", required=True, help="directory written by run-tree.sh")
    parser.add_argument("--base", default="base", help="label of the earlier tree (default base)")
    parser.add_argument("--head", default="head", help="label of the later tree (default head)")
    args = parser.parse_args(argv)
    outputs = Outputs(args.inputs, args.out, args.base, args.head)
    print(f"w doubling measurement: {args.base} against {args.head}")
    unflagged = 0
    try:
        for correction in (0, 1):
            print(f"\n== typoCorrection {'on' if correction else 'off'} (c{correction})")
            unchanged_sets(outputs, correction)
            habit(outputs, correction)
            capital_inner(outputs, correction)
            unflagged += random_sequences(outputs, correction)
    except LengthMismatch as error:
        print(f"compare: {error}", file=sys.stderr)
        return 1
    return 1 if unflagged else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
