"""Scratch reference model of the orthography rules written for spec/01-engine.md.
Own code, written from the spec text only. Not shipped."""
import unicodedata

VOWELS = set("aăâeêioôơuưy")
TONE_MARKS = {1: "́", 2: "̀", 3: "̉", 4: "̃", 5: "̣"}
STOP_CODAS = ("c", "ch", "p", "t", "k")

# ---- Tier A rhymes (context: ordinary consonant onset or zero onset) ----
R_A = """a ac ach ai am an ang anh ao ap at au ay
oa oac oach oai oam oan oang oanh oat oay
ăc ăm ăn ăng ăp ăt
oăc oăm oăn oăng oăt
âc âm ân âng âp ât âu ây
uân uâng uât uây
e ec em en eng eo ep et
oe oen oeo oet
ê êch êm ên ênh êp êt êu
uê uêch uênh
i ich im in inh ip it iu
y
uy uych uyn uynh uyp uyt uyu
ia iêc iêm iên iêng iêp iêt iêu
yêm yên yêng yêt yêu
uya uyên uyêt
o oc oi om on ong op ot
ooc oong
ô ôc ôi ôm ôn ông ôp ôt
ơ ơi ơm ơn ơp ơt
uơ
u uc ui um un ung up ut
ua uôc uôi uôm uôn uông uôt
ư ưc ưi ưng ưt ưu
ưa ươc ươi ươm ươn ương ươp ươt ươu""".split()

R_QU_A = """a ac ach ai an ang anh ao at au ay
ăc ăm ăn ăng ăp ăt
ân âng ât ây
e en eo et
ê êch ên ênh êt êu
i it y ych ynh yt yên yêt
ơ ôc""".split()

R_B_EXTRA = """oao oap oăp oem oeng oec oep uên uêt uêu ưm ưn ưp""".split()
R_QU_B_EXTRA = ["o", "ơn"]

MEDIAL_PREFIXES = ("oa", "oă", "oe", "uâ", "uê", "uy", "uơ")  # uya/uyê start with uy
FRONT_START = ("e", "ê", "i", "y")

ONSETS_A = ["", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n",
            "ng", "ngh", "nh", "p", "ph", "qu", "r", "s", "t", "th", "tr", "v", "x"]
ONSETS_B_EXTRA = ["bl", "br", "dr", "đr", "gl", "gr", "kl", "kr", "pl", "pr", "z"]
LABIALS = {"b", "m", "p", "ph", "v"}
Y_OPEN_ONSETS_A = {"", "h", "k", "l", "m", "s", "t", "v"}


def is_medial(r):
    return r.startswith(MEDIAL_PREFIXES)


def is_front(r):
    return r.startswith(FRONT_START)


def rhyme_ok(onset, r, tier):
    """Is rhyme r allowed after onset under tier 'A' or 'B'?"""
    B = tier == "B"
    base_onset = onset
    if onset == "qu":
        return r in R_QU_A or (B and r in R_QU_B_EXTRA)
    if onset == "gi":
        if r == "êng":
            return True
        if r.startswith(("i", "y")):
            return False
        if is_medial(r):
            return B and r.startswith(("oa", "oă", "oe"))
        return r in R_A or (B and r in R_B_EXTRA)
    # k-coda alias (tier B): rhyme ending in k treated as c
    if B and r.endswith("k") and not r.endswith("nh"):
        rc = r[:-1] + "c"
        if rc in R_A or rc in R_B_EXTRA:
            return rhyme_ok(onset, rc, tier)
        return False
    if r not in R_A and not (B and r in R_B_EXTRA):
        return False
    # zero-onset specifics
    if r.startswith("yê") and onset != "":
        return False
    if onset == "" and r.startswith("iê"):
        return False
    if r == "y" and onset not in Y_OPEN_ONSETS_A and not B:
        return False
    if r == "uơ" and onset not in ("h", "th") and not B:
        return False
    # first-consonant of cluster decides labial/front rules
    head = onset
    if onset in ONSETS_B_EXTRA:
        head = onset[0] if onset != "đr" else "đ"
    if is_medial(r):
        if head in ("c", "k", "gh", "ngh"):
            return False
        if head in LABIALS and not B:
            return False
    if onset in ("k", "gh", "ngh"):
        if not is_front(r):
            return B and onset == "k"
    if onset in ("c", "ng"):
        if is_front(r):
            return False
    if onset == "g":
        if r.startswith(("e", "ê")):
            return False
        # g + i-rhymes = collapsed gi onset: allowed (but not y / ia / iê)
        if r.startswith("y") or r.startswith("ia") or r.startswith("iê"):
            return False
    return True


def tones_for(r):
    return (1, 5) if r.endswith(STOP_CODAS) else (0, 1, 2, 3, 4, 5)


def all_syllables(tier):
    onsets = ONSETS_A + (ONSETS_B_EXTRA if tier == "B" else [])
    rhymes = R_A + (R_B_EXTRA if tier == "B" else [])
    if tier == "B":
        rhymes = rhymes + [r[:-1] + "k" for r in rhymes if r.endswith("c")]
    out = set()
    for o in onsets:
        pool = rhymes + (R_QU_A + R_QU_B_EXTRA if o == "qu" else []) + (["êng"] if o == "gi" else [])
        for r in set(pool):
            if rhyme_ok(o, r, tier):
                out.add((o, r))
    return out


# ---------------- letters ----------------
class L:
    __slots__ = ("base", "mod", "stroke", "upper", "fromw", "src", "msrc")

    def __init__(self, base, mod="", stroke=False, upper=False, fromw=False, src=-1, msrc=None):
        self.base, self.mod, self.stroke, self.upper, self.fromw = base, mod, stroke, upper, fromw
        self.src = src
        self.msrc = list(msrc or [])

    def copy(self):
        return L(self.base, self.mod, self.stroke, self.upper, self.fromw, self.src, self.msrc)

    def char(self):
        b = self.base
        if b == "d" and self.stroke:
            return "đ"
        return {("a", "breve"): "ă", ("a", "circ"): "â", ("e", "circ"): "ê", ("o", "circ"): "ô",
                ("o", "horn"): "ơ", ("u", "horn"): "ư"}.get((b, self.mod), b)


def norm_letters(ls):
    """display normalisation: in a u+o pair, horn on either -> horn on both."""
    ls = [x.copy() for x in ls]
    for i in range(len(ls) - 1):
        a, b = ls[i], ls[i + 1]
        if i == 1 and ls[0].base == "q":
            continue  # the u of the qu onset never takes a horn
        if a.base == "u" and b.base == "o" and (a.mod == "horn" or b.mod == "horn") and b.mod != "circ":
            a.mod = "horn"
            b.mod = "horn"
    return ls


ONSET_TRY = ["ngh", "ng", "nh", "ch", "gh", "kh", "ph", "th", "tr",
             "bl", "br", "dr", "đr", "gl", "gr", "kl", "kr", "pl", "pr"]


def parse(s):
    """s: lowercase letter string (with mods). returns (onset, vowelrun, coda, rest) by position."""
    n = len(s)
    onset = ""
    if s.startswith("qu"):
        onset = "qu"
    elif s.startswith("gi") and n > 2 and s[2] in VOWELS:
        onset = "gi"
    else:
        for o in ONSET_TRY:
            if s.startswith(o):
                onset = o
                break
        else:
            if n and s[0] not in VOWELS:
                onset = s[0]
    i = len(onset)
    j = i
    while j < n and s[j] in VOWELS:
        j += 1
    k = j
    while k < n and s[k] not in VOWELS:
        k += 1
    return onset, s[i:j], s[j:k], s[k:], i, j


def tone_target(s, style):
    """index into s of the tone-bearing letter, or None."""
    onset, run, coda, rest, i, j = parse(s)
    if not run:
        return None
    modded = [p for p in range(i, j) if s[p] in "ăâêôơư"]
    if modded:
        return modded[-1]
    if coda:
        return j - 1
    if len(run) == 1:
        return i
    if len(run) == 2:
        if run in ("oa", "oe", "uy"):
            return i if style == "old" else i + 1
        return i
    if len(run) == 3:
        return i + 1
    return i + 1


def apply_tone(ch, tone):
    if tone == 0:
        return ch
    return unicodedata.normalize("NFC", ch + TONE_MARKS[tone])


def render(ls, tone, style):
    ls = norm_letters(ls)
    s = "".join(x.char() for x in ls)
    t = tone_target(s, style) if tone else None
    out = []
    for idx, x in enumerate(ls):
        c = s[idx]
        if idx == t:
            c = apply_tone(c, tone)
        out.append(c.upper() if x.upper else c)
    return "".join(out)


def strip(s):
    """remove tone marks, keep vowel modifiers"""
    d = unicodedata.normalize("NFD", s)
    d = "".join(c for c in d if c not in TONE_MARKS.values())
    return unicodedata.normalize("NFC", d)


def validity(word):
    """word: NFC lowercase display. returns 'A', 'B' or None."""
    w = word.lower()
    tone = 0
    for t, m in TONE_MARKS.items():
        if m in unicodedata.normalize("NFD", w):
            tone = t
    s = strip(w)
    onset, run, coda, rest, i, j = parse(s)
    if rest or not run:
        return None
    r = run + coda
    for tier in ("A", "B"):
        if tier == "A" and onset in ONSETS_B_EXTRA:
            continue
        if tier == "A" and r.endswith("k"):
            continue
        tones = tones_for(r) if not (tier == "B" and r.endswith("k")) else (0, 1, 2, 3, 4, 5)
        if rhyme_ok(onset, r, tier) and tone in tones:
            return tier
    return None


# ---------------- viability ----------------
_PREFIX = None


def _build_prefix():
    global _PREFIX
    _PREFIX = {}
    for o, r in all_syllables("B"):
        full = o + r
        for k in range(1, len(full) + 1):
            p = full[:k]
            base = basekey(p)
            _PREFIX.setdefault(base, set()).add(p)


def basekey(s):
    out = []
    for c in s:
        out.append({"ă": "a", "â": "a", "ê": "e", "ô": "o", "ơ": "o", "ư": "u", "đ": "d"}.get(c, c))
    return "".join(out)


def compatible(cur, cand):
    for a, b in zip(cur, cand):
        if a == b:
            continue
        if a in "aeou" and basekey(b) == a:
            continue
        if a == "d" and b == "đ":
            continue
        return False
    return True


def viable(ls):
    if _PREFIX is None:
        _build_prefix()
    if not ls:
        return True
    s = "".join(x.char() for x in norm_letters(ls))
    cands = _PREFIX.get(basekey(s))
    if not cands:
        return False
    return any(compatible(s, c) for c in cands)
