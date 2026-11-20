# SPDX-License-Identifier: MPL-2.0
"""Reference model of the typo correction of spec/01-engine.md section 11A (ENG-R1110 to ENG-R1114 and ENG-R1125),
written from the spec text only (no other input method's code or data was consulted). Not shipped: a cross-check of
the engine and of the bundled data, as the rest of this directory.

Inputs: the bundled `english.txt` and tech lists, the collision list (`ambiguity.tsv` and `collision-supplement.txt`),
the guard words read from the pinned SCOWL inputs (the exact words, not the bundled filter), the QWERTY table as
ENG-R1113 writes it, and the unmarked shapes and Vietnamese keyings generated here from the tier tables of `ortho.py`.
The decision of 8.1 that decides whether a token is a candidate comes from `boundary.decide` over the bundled lists.

    python3 -I correction.py --self-check    the 13.12 rows the model can decide, and the data cross-checks

Known gaps: the decision of 8.1 is `boundary.py`'s (the English run is approximated by the previous token alone; the
user's toggle, the collision memory and the revisions of ENG-R828 are not modelled); the undo and re-opening of
ENG-R1117 are not modelled (rows with a restore toggle or a Backspace are skipped).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import boundary  # noqa: E402
import ortho  # noqa: E402
from compose import Cfg  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(REPO, "Packages", "VietnameseEngine", "Sources", "VietnameseEngineData", "Resources")
SCOWL = os.path.join(REPO, "data", "inputs", "english", "scowl-2020.12.07")
FIXTURE = os.path.join(REPO, "Packages", "VietnameseEngine", "Tests", "VietnameseEngineTests", "Corpus",
                       "typo-corrections.tsv")

LETTERS = "abcdefghijklmnopqrstuvwxyz"
MINIMUM_LETTERS, MAXIMUM_LETTERS, MINIMUM_FIT_LETTERS = 5, 24, 4  # ENG-R1111, ENG-R1114
CLOSERS = set('.,;:!?)]}"')  # ENG-R1112, plus whitespace, Return and Tab (Q11: every committing key)
OPENERS = {" ", " ", "(", "[", "{", '"', "“", "‘", "'"}
SENTENCE_ENDS = set(".!?:")
CLUSTER_ONSETS = {"bl", "br", "dr", "đr", "gl", "gr", "kl", "kr", "pl", "pr"}  # ENG-R1110 (b)

# ENG-R1113, as the spec writes it.
NEIGHBOURS = {
    "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh", "u": "yihj", "i": "uojk",
    "o": "ipkl", "p": "ol", "a": "qwsz", "s": "weadzx", "d": "ersfxc", "f": "rtdgcv", "g": "tyfhvb", "h": "yugjbn",
    "j": "uihknm", "k": "iojlm", "l": "opk", "z": "asx", "x": "sdzc", "c": "dfxv", "v": "fgcb", "b": "ghvn",
    "n": "hjbm", "m": "jkn",
}

GUARD_FILES = [f"{c}-words.{n}" for c in ("english", "american", "british", "british_z") for n in (40, 50, 55, 60, 70)]
GUARD_FILES += [f"english-proper-names.{n}" for n in (35, 40, 50, 60, 70)] + ["american-proper-names.50"]


def _lines(name):
    with open(os.path.join(RESOURCES, name), encoding="utf-8") as handle:
        return [line for line in handle.read().split("\n") if line]


def _letters_only(word):
    return word.isascii() and word.isalpha() and word.islower()


# ---- data ----

class Data:
    """The lists of ENG-R1110 (c), the correction lexicon of ENG-R1114 and the Vietnamese data of ENG-R1125."""

    def __init__(self, guard=True):
        self.english = set(_lines("english.txt"))
        self.tech_always = set(_lines("tech-always.txt"))
        self.code_only = set(_lines("tech-code-only.txt"))
        rows = [line.split("\t") for line in _lines("ambiguity.tsv")[1:]]
        self.ambiguity = {row[0]: ("vi" if row[2] == "unreviewed" else row[1]) for row in rows}
        self.collision = set(self.ambiguity) | set(_lines("collision-supplement.txt"))
        self.lexicon = self.english | {w for w in self.tech_always if _letters_only(w)}
        self.guard = guard_words(self.lexicon) if guard else set()
        self.attested = set(_lines("attested.txt"))
        self.shapes = unmarked_shapes()
        self.keyings = vietnamese_keyings()
        self.vietnamese = self.shapes | self.keyings

    def on_a_list(self, word, user=()):
        return (word in self.english or word in self.tech_always or word in self.code_only or word in self.guard
                or word in self.collision or word in user)


def guard_words(lexicon):
    """ENG-R1120 (2): the lowercase a-z entries of five letters or more of the 26 guard list members, minus the
    correction lexicon."""
    words = set()
    for name in GUARD_FILES:
        with open(os.path.join(SCOWL, name), encoding="iso-8859-1") as handle:
            for raw in handle.read().splitlines():
                word = raw.strip().lower()
                if len(word) >= MINIMUM_LETTERS and _letters_only(word) and word not in lexicon:
                    words.add(word)
    return words


# ---- shapes and keyings from the tier tables (ENG-R1110 (d), ENG-R1125) ----

# ortho.py predates three spec additions (README, known gaps): `giếc` (ENG-R305), open `y` after `th` (ENG-R314) and
# the Tier B onset `dz` (ENG-R316). They are added here; `dz` takes the rhymes of `z`.
PLAIN = str.maketrans("ăâêôơưđ", "aaeooud")
MARK_KEYS = {"ă": "aw", "â": "aa", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd"}
TONE_KEYS = {0: "", 1: "s", 2: "f", 3: "r", 4: "x", 5: "j"}


def syllables(tier):
    pairs = set(ortho.all_syllables(tier))
    pairs.discard(("g", "iu"))  # 3.13 reads `giu` as gi + u only (README, known gap 3)
    pairs |= {("gi", "êc"), ("th", "y")}
    if tier == "B":
        pairs |= {("dz", r) for (o, r) in list(pairs) if o == "z"}
    return pairs


def unmarked_shapes():
    return {(o + r).translate(PLAIN) for (o, r) in syllables("B")}


def vowel_forms(onset, vowels):
    """ENG-R1125 (ii) and (iii): each vowel letter as its keys, `ươ` as `uwow` or `uow`, and a leading `ư` as `w`
    alone after a consonant other than `q`."""
    if not vowels.startswith("ư"):
        return ["".join(MARK_KEYS.get(c, c) for c in vowels)]
    horn_pair = vowels.startswith("ươ")
    rest = "".join(MARK_KEYS.get(c, c) for c in vowels[2 if horn_pair else 1:])
    leads = ["uwow", "uow"] if horn_pair else ["uw"]
    if onset not in ("", "qu"):
        leads.append("wow" if horn_pair else "w")
    return [lead + rest for lead in leads]


def vietnamese_keyings():
    keyings = set()
    for onset, rhyme in syllables("A"):
        count = 0
        while count < len(rhyme) and rhyme[count] in ortho.VOWELS:
            count += 1
        vowels, coda = rhyme[:count], rhyme[count:]
        onset_keys = "".join(MARK_KEYS.get(c, c) for c in onset)
        for form in vowel_forms(onset, vowels):
            for tone in ortho.tones_for(rhyme):
                key = TONE_KEYS[tone]
                keyings.add(onset_keys + form + coda + key)
                if coda and key:
                    keyings.add(onset_keys + form + key + coda)
    return keyings


# ---- edits (ENG-R1113) and the one-word rule (ENG-R1114) ----

def edits(word, position_rules=True):
    """The words at distance one: transposition of neighbouring letters, deletion, insertion and substitution by a
    neighbouring key; with `position_rules` the four rules of ENG-R1113 (ENG-R1125 enumerates without them)."""
    n, out = len(word), set()
    for i in range(n - 1):
        if word[i] != word[i + 1]:
            out.add(word[:i] + word[i + 1] + word[i] + word[i + 2:])
    for i in range(n):
        if position_rules and i == 0 and not (n > 1 and word[0] == word[1]):
            continue
        if position_rules and i == n - 1 and not (n > 1 and word[-1] == word[-2]):
            continue
        out.add(word[:i] + word[i + 1:])
    for i in range(n + 1):
        for c in LETTERS:
            if position_rules and i == n and c != word[-1]:
                continue
            out.add(word[:i] + c + word[i:])
    for i in range(n):
        for c in NEIGHBOURS[word[i]]:
            if position_rules and i == n - 1 and i > 0 and word[i] == "r" and c == "d" and word[i - 1] == "e":
                continue
            out.add(word[:i] + c + word[i + 1:])
    out.discard(word)
    return out


def fits(word, data):
    return {e for e in edits(word, True) if len(e) >= MINIMUM_FIT_LETTERS and e in data.lexicon}


def within_one_edit_of_vietnamese(word, data):
    return any(e in data.vietnamese for e in edits(word, False))


def elongated(word):
    return len(word) >= 3 and word[-1] == word[-2] == word[-3]


def rule_correction(word, data, user=(), vietnamese_rule=True):
    """The rules that read the typed word alone (ENG-R1110 (c), (d) shapes and ENG-R1125, ENG-R1111 letters and
    elongation, ENG-R1114): the single fit, or None. `word` is lowercase."""
    if not _letters_only(word) or not MINIMUM_LETTERS <= len(word) <= MAXIMUM_LETTERS or elongated(word):
        return None
    if data.on_a_list(word, user) or word in data.shapes:
        return None
    found = fits(word, data)
    if len(found) != 1:
        return None
    if vietnamese_rule and within_one_edit_of_vietnamese(word, data):
        return None
    return next(iter(found))


# ---- a token in its context (ENG-R1110 (a), (b), ENG-R1111 case, ENG-R1112) ----

def candidate_decision(reason, display, raw):
    """ENG-R1110 (b) and the display half of (d): L0 or a restore by any rule but the user's (the model has no L1 or
    L2 restores) whose display `C` is neither Tier A nor Tier B, or the cluster case (a display kept by L6 whose onset
    is a place-name cluster, typed in lowercase)."""
    if reason == "unchanged" or reason.startswith("restored"):
        return ortho.validity(display.lower()) is None
    if reason == "kept: Tier B, not English" and raw == raw.lower():
        onset = ortho.parse(ortho.strip(display.lower()))[0]
        return onset in CLUSTER_ONSETS
    return False


def correct_token(raw, reason, display, commit_key, before, line_start, sentence_start, data, context="general",
                  user=()):
    """The correction of one committed token, or None (the token commits as in 1.0)."""
    if context == "code":
        return None
    if not (commit_key in (" ", "\n", "\t") or commit_key in CLOSERS):
        return None
    if not (before in OPENERS or (line_start and before in (None, "\t"))):
        return None
    if not candidate_decision(reason, display, raw):
        return None
    lower = raw.lower()
    if raw != lower and not (sentence_start and raw[0].isupper() and raw[1:] == lower[1:]):
        return None
    fix = rule_correction(lower, data, user)
    if fix is None:
        return None
    return fix[0].upper() + fix[1:] if raw[0].isupper() else fix


def patch_boundary(data):
    """`boundary.decide` reads module-level fixture lists; the model points them at the bundled data."""
    class NotAttested:
        def __contains__(self, syllable):
            return ortho.validity(syllable) == "A" and syllable not in data.attested

    boundary.EN = data.english
    boundary.TECH = data.tech_always
    boundary.CODE_ONLY = data.code_only
    boundary.NOT_ATTESTED = NotAttested()
    boundary.AMBIG = {raw: decision for raw, decision in data.ambiguity.items()}


def is_token_key(ch, im):
    return (ch.isascii() and ch.isalpha()) or (im == "vni" and ch.isdigit())


def type_line(keys, data, im="telex", context="general", user=(), correction=True):
    """Types `keys` from an empty field: every token committed by a boundary key is decided by 8.1 and, with
    `correction`, by section 11A. Returns the field."""
    cfg = Cfg(im)
    out, i, prev_lang, boundary_text, first = "", 0, "neutral", "", True
    while i < len(keys):
        if not is_token_key(keys[i], im):
            boundary_text += keys[i]
            out += keys[i]
            i += 1
            continue
        j = i
        while j < len(keys) and is_token_key(keys[j], im):
            j += 1
        raw = keys[i:j]
        sentence_start = first or any(c in SENTENCE_ENDS for c in boundary_text)
        line_start = (first or "\n" in boundary_text) and boundary_text.split("\n")[-1].strip(" \t") == ""
        before = boundary_text[-1] if boundary_text else None
        if j == len(keys):  # not committed: the field shows the display
            out += boundary.display(boundary.compose(list(raw), cfg), cfg)
            break
        shown, reason = boundary.decide(raw, cfg, prev=prev_lang, context=context, starts_sentence=sentence_start)
        display = boundary.commit(boundary.compose(list(raw), cfg), cfg)
        fixed = None
        if correction:
            # The typed word: the keys a restore puts back, `R`, or `R'` when rule L4 left out a `w` doubling (REG-40).
            typed = shown if reason.startswith("restored") else raw
            fixed = correct_token(typed, reason, display, keys[j], before, line_start, sentence_start, data, context,
                                  user)
        out += fixed if fixed is not None else shown
        prev_lang = "en" if fixed is not None or reason.startswith("restored") else "neutral"
        boundary_text, first, i = "", False, j
    return out


# ---- self-check ----

def unescape(text):
    return text.replace("\\s", " ").replace("\\n", "\n").replace("\\t", "\t")


def self_check(data):
    patch_boundary(data)
    checked, skipped, failures = 0, [], []
    with open(FIXTURE, encoding="utf-8") as handle:
        rows = [line.split("\t") for line in handle.read().split("\n") if line and not line.startswith("#")][1:]
    for row in rows:
        ident, method, setup, keys, expected, expected_off = row[:6]
        keys, expected, expected_off = unescape(keys), unescape(expected), unescape(expected_off)
        if "⌫" in keys or "⎋" in keys or setup.startswith(("macro:", "after:")):
            skipped.append(ident)
            continue
        im = "vni" if method == "VNI" else "telex"
        context = "code" if setup == "code" else "general"
        user = {setup.split(":", 1)[1]} if setup.startswith(("never:", "keep:")) else set()
        off = type_line(keys, data, im, context, user, correction=False)
        if off != expected_off:  # the model's 1.0 decision differs from the engine's: not decidable here
            skipped.append(ident)
            continue
        on = type_line(keys, data, im, context, user, correction=setup != "off")
        checked += 1
        if on != expected:
            failures.append(f"{ident}: model {on!r}, spec {expected!r}")
    print(f"13.12: {checked} rows checked, {len(failures)} differ, {len(skipped)} skipped "
          f"({', '.join(skipped)})")
    for failure in failures:
        print("  " + failure)
    return not failures


def data_check(data):
    """The model's shapes, keyings and table against the bundled files (ENG-T56 has the engine's own check)."""
    ok = True
    for name, model in (("unmarked-shapes.txt", data.shapes), ("vietnamese-keyings.txt", data.keyings)):
        bundled = set(_lines(name))
        only_model, only_bundled = sorted(model - bundled), sorted(bundled - model)
        print(f"{name}: model {len(model)}, bundled {len(bundled)}, only in the model {len(only_model)} "
              f"{only_model[:8]}, only bundled {len(only_bundled)} {only_bundled[:8]}")
        ok = ok and not only_model and not only_bundled
    table = {line.split("\t")[0]: line.split("\t")[1] for line in _lines("keyboard-neighbours.txt")}
    same_table = table == NEIGHBOURS
    print(f"keyboard-neighbours.txt equals the table of ENG-R1113: {same_table}")
    symmetric = all(a in NEIGHBOURS[b] for a in NEIGHBOURS for b in NEIGHBOURS[a])
    print(f"the table of ENG-R1113 is symmetric and covers 26 letters: {symmetric and len(NEIGHBOURS) == 26}")
    print(f"guard words (exact, from the pinned inputs): {len(data.guard)}")
    return ok and same_table and symmetric


def main(argv):
    if argv[1:] != ["--self-check"]:
        print(__doc__)
        return 2
    data = Data()
    passed = data_check(data)
    passed = self_check(data) and passed
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
