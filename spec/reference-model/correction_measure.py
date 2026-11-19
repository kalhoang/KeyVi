# SPDX-License-Identifier: MPL-2.0
"""Measurements of the typo correction model (`correction.py`) for the targets of spec/01-engine.md ENG-R1124: injected
typos (ENG-T52), rare words (ENG-T53) and one-key typos of Vietnamese words (ENG-T57). A cross-check: the gates are
ENG-T52, ENG-T53 and ENG-T57 on the engine. Written from the spec text only. Not shipped.

    python3 -I correction_measure.py --seed 18112026 [--words N] [--dictionary /usr/share/dict/words]

ENG-T52 is measured twice: on the rules that read the typed word alone (as the design note of 18/11/2026 measured
it) and with the decision of 8.1 first (a typo whose display is a Vietnamese syllable is not a candidate, as in the
engine). ENG-T53 reads the rules alone. ENG-T57 types each typo through the composition model and the decision of 8.1
(`boundary.decide`) before the correction.
"""
import argparse
import os
import random
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import boundary  # noqa: E402
import correction  # noqa: E402
import ortho  # noqa: E402
from compose import Cfg  # noqa: E402

PROSE = os.path.join(correction.REPO, "data", "corpus", "prose-vi.txt")
KINDS_T52 = ("transposition", "omission", "insertion", "doubling", "neighbour")
KINDS_T57 = ("transposition", "omission", "insertion", "neighbour")
CFG = Cfg("telex")


def typo(word, kind, rng):
    """One random edit of `kind`, or None when the word allows none (a transposition of two equal letters is not a
    typo)."""
    n = len(word)
    if kind == "transposition":
        places = [i for i in range(n - 1) if word[i] != word[i + 1]]
        if not places:
            return None
        i = rng.choice(places)
        return word[:i] + word[i + 1] + word[i] + word[i + 2:]
    if kind == "omission":
        i = rng.randrange(n)
        return word[:i] + word[i + 1:]
    if kind == "insertion":
        i = rng.randrange(n + 1)
        return word[:i] + rng.choice(correction.LETTERS) + word[i:]
    if kind == "doubling":
        i = rng.randrange(n)
        return word[:i] + word[i] + word[i:]
    i = rng.randrange(n)
    return word[:i] + rng.choice(correction.NEIGHBOURS[word[i]]) + word[i + 1:]


def engine_correction(keys, data, vietnamese_rule=True):
    """The token typed after a Vietnamese word and a space, committed by a space: the decision of 8.1, then 11A."""
    shown, reason = boundary.decide(keys, CFG, prev="neutral")
    display = boundary.commit(boundary.compose(list(keys), CFG), CFG)
    if not correction.candidate_decision(reason, display, keys):
        return None
    return correction.rule_correction(keys, data, vietnamese_rule=vietnamese_rule)


def percent(part, whole):
    return f"{100 * part / whole:.2f} %" if whole else "n/a"


def measure_t52(data, seed, count):
    words = sorted(w for w in data.english if len(w) >= correction.MINIMUM_LETTERS)
    rng = random.Random(seed)
    print(f"ENG-T52 injected typos: {count} lexicon words of five letters or more per kind, seed {seed}")
    print("| Kind | to the source (rules) | to another word (rules) | to the source (8.1 first) | "
          "to another word (8.1 first) | to the source without ENG-R1125 (rules) |")
    print("|---|---|---|---|---|---|")
    for kind in KINDS_T52:
        sample = rng.sample(words, count)
        counts = {"source": 0, "other": 0, "source81": 0, "other81": 0, "source_no1125": 0}
        typos = 0
        for word in sample:
            typed = typo(word, kind, rng)
            if typed is None:
                continue
            typos += 1
            fix = correction.rule_correction(typed, data)
            counts["source" if fix == word else "other"] += fix is not None
            fix81 = engine_correction(typed, data) if fix is not None else None
            counts["source81" if fix81 == word else "other81"] += fix81 is not None
            counts["source_no1125"] += correction.rule_correction(typed, data, vietnamese_rule=False) == word
        print(f"| {kind} ({typos}) | {percent(counts['source'], typos)} | {percent(counts['other'], typos)} | "
              f"{percent(counts['source81'], typos)} | {percent(counts['other81'], typos)} | "
              f"{percent(counts['source_no1125'], typos)} |")


def measure_t53(data, dictionary):
    if not os.path.exists(dictionary):
        print(f"ENG-T53: {dictionary} is absent, skipped")
        return
    with open(dictionary, encoding="utf-8", errors="replace") as handle:
        words = {w.strip().lower() for w in handle}
    words = {w for w in words if len(w) >= correction.MINIMUM_LETTERS and correction._letters_only(w)}
    tech = data.tech_always | data.code_only
    design = sorted(w for w in words if w not in data.english and w not in tech)
    spec = [w for w in sorted(words) if w not in data.english and w not in data.guard]
    corrected_without_guard, corrected_with_guard, corrected_spec = [], 0, []
    no_guard = correction.Data.__new__(correction.Data)
    no_guard.__dict__.update(data.__dict__)
    no_guard.guard = set()
    for word in design:
        fix = correction.rule_correction(word, no_guard)
        if fix is not None:
            corrected_without_guard.append(f"{word}>{fix}")
            corrected_with_guard += word not in data.guard
    for word in spec:
        fix = correction.rule_correction(word, data)
        if fix is not None:
            corrected_spec.append(f"{word}>{fix}")
    print(f"ENG-T53 rare words ({dictionary}, five ASCII letters or more):")
    print(f"- outside the lexicon and the tech lists ({len(design)} words), without the guard list: "
          f"{len(corrected_without_guard)} corrected, {percent(len(corrected_without_guard), len(design))}")
    print(f"- the same words with the guard list: {corrected_with_guard} corrected, "
          f"{percent(corrected_with_guard, len(design))}")
    print(f"- outside the lexicon and the guard list ({len(spec)} words, the denominator of ENG-T53): "
          f"{len(corrected_spec)} corrected, {percent(len(corrected_spec), len(spec))}")
    print(f"  first corrections: {', '.join(corrected_spec[:12])}")


TELEX_MARKS = {"ă": "aw", "â": "aa", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd"}
TELEX_TONES = {"́": "s", "̀": "f", "̉": "r", "̃": "x", "̣": "j"}


def telex_keys(word):
    """The Telex keys of a lowercase syllable in the usual order with the tone key last; the horn of `ươ` once,
    after the `o` (`uow`)."""
    tone = ""
    letters = []
    for ch in unicodedata.normalize("NFD", word):
        if ch in TELEX_TONES:
            tone = TELEX_TONES[ch]
        elif unicodedata.combining(ch):
            letters[-1] = unicodedata.normalize("NFC", letters[-1] + ch)
        else:
            letters.append(ch)
    keys = ""
    for index, letter in enumerate(letters):
        if letter == "ư" and index + 1 < len(letters) and letters[index + 1] == "ơ":
            keys += "u"
        else:
            keys += TELEX_MARKS.get(letter, letter)
    return keys + tone


def prose_words():
    words = set()
    with open(PROSE, encoding="utf-8") as handle:
        for line in handle:
            if not line.startswith("#"):
                words.update(token.lower() for token in line.split())
    return sorted(words)


def measure_t57(data, seed):
    rng = random.Random(seed)
    sources = [w for w in prose_words() if ortho.validity(w) is not None]
    print(f"ENG-T57 one-key typos of the {len(sources)} distinct Tier A or Tier B words of the prose corpus, "
          f"seed {seed}, typed after a Vietnamese word:")
    plain = sorted({ortho.strip(w).translate(correction.PLAIN) for w in sources})
    for label, typed_words in (("Telex, tone key last", [telex_keys(w) for w in sources]),
                               ("plain letters (each distinct shape once)", plain)):
        typos, with_rule, without_rule = 0, [], []
        for keys in typed_words:
            word = keys
            for kind in KINDS_T57:
                typed = typo(keys, kind, rng)
                if typed is None or len(typed) < correction.MINIMUM_LETTERS or typed == keys:
                    continue
                if label.startswith("plain") and (data.on_a_list(typed) or typed in data.shapes):
                    continue  # the design's plain-letter run counts the typos that are neither words nor shapes
                typos += 1
                fix = engine_correction(typed, data)
                if fix is not None:
                    with_rule.append(f"{typed}>{fix} ({word})")
                fix = engine_correction(typed, data, vietnamese_rule=False)
                if fix is not None:
                    without_rule.append(f"{typed}>{fix}")
        print(f"- {label}: {typos} typos of five keys or more; corrected to an English word: {len(with_rule)} "
              f"({percent(len(with_rule), typos)}), without ENG-R1125 {len(without_rule)}")
        if with_rule:
            print(f"  {', '.join(with_rule[:20])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=18112026)
    parser.add_argument("--words", type=int, default=6000, help="ENG-T52 words per kind")
    parser.add_argument("--dictionary", default="/usr/share/dict/words")
    arguments = parser.parse_args()
    data = correction.Data()
    correction.patch_boundary(data)
    measure_t52(data, arguments.seed, arguments.words)
    measure_t53(data, arguments.dictionary)
    measure_t57(data, arguments.seed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
