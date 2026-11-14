# SPDX-License-Identifier: MPL-2.0
"""Scratch composition model (Telex / VNI) following spec/01-engine.md. Not shipped."""
from ortho import L, render, viable, parse, norm_letters, VOWELS, validity, strip
import unicodedata

TELEX_TONES = {"s": 1, "f": 2, "r": 3, "x": 4, "j": 5}
VNI_TONES = {"1": 1, "2": 2, "3": 3, "4": 4, "5": 5}


class Cfg:
    def __init__(self, im="telex", style="old", standalone_w=True, brackets=False):
        self.im, self.style, self.standalone_w, self.brackets = im, style, standalone_w, brackets


class St:
    def __init__(self):
        self.ls = []
        self.tone = 0
        self.literal = False
        self.frozen = ""
        self.escaped = set()
        self.raw = []
        self.free_order = False  # a modifier/stroke applied non-adjacently
        self.had_escape = False
        self.tone_src = []
        self.shown = None  # re-opened word: the text the commit left on screen (ENG-R1002)

    def copy(self):
        n = St()
        n.ls = [x.copy() for x in self.ls]
        n.tone, n.literal, n.frozen = self.tone, self.literal, self.frozen
        n.escaped = set(self.escaped)
        n.raw = list(self.raw)
        n.free_order, n.had_escape = self.free_order, self.had_escape
        n.tone_src = list(self.tone_src)
        return n


def letters_str(ls):
    return "".join(x.char() for x in norm_letters(ls))


def run_span(ls):
    s = letters_str(ls)
    onset, run, coda, rest, i, j = parse(s)
    return onset, i, j, coda


def display(st, cfg):
    if st.shown is not None:
        return st.shown
    if st.literal:
        return st.frozen
    return render(st.ls, st.tone, cfg.style)


def freeze_with(st, cfg, ch):
    st.frozen = render(st.ls, st.tone, cfg.style) + ch
    st.literal = True


def append_letter(st, cfg, ch):
    """append a plain letter (or literal char); enter literal mode if not viable."""
    lc = ch.lower()
    if lc.isascii() and lc.isalpha():
        cand = st.ls + [L(lc, upper=ch.isupper(), src=len(st.raw) - 1)]
        if viable(cand):
            st.ls = cand
            return
    freeze_with(st, cfg, ch)


def escape(st, cfg, kind, ch):
    st.escaped.add(kind)
    st.had_escape = True
    append_letter(st, cfg, ch)


def try_tone(st, cfg, t, ch):
    onset, i, j, coda = run_span(st.ls)
    if i == j or "tone" in st.escaped:
        return False
    st.tone_src.append(len(st.raw) - 1)
    if st.tone == t:
        st.tone = 0
        escape(st, cfg, "tone", ch)
        return True
    st.tone = t
    return True


def try_untone(st, cfg, ch):
    if st.tone == 0:
        return False
    st.tone = 0
    st.tone_src.append(len(st.raw) - 1)
    return True


def adjacent(st, idx):
    """target letter is the last letter typed so far (adjacent entry)"""
    return idx == len(st.ls) - 1


def try_circ(st, cfg, ch, base=None):
    if "circ" in st.escaped:
        return False
    onset, i, j, coda = run_span(st.ls)
    cands = [p for p in range(j - 1, i - 1, -1)
             if (st.ls[p].base == base if base else st.ls[p].base in "aeo")]
    for p in cands:
        if st.ls[p].mod == "circ":
            st.ls[p].mod = ""
            escape(st, cfg, "circ", ch)
            return True
        new = [x.copy() for x in st.ls]
        new[p].mod = "circ"
        new[p].msrc.append(len(st.raw) - 1)
        if new[p].base == "o" and p - 1 >= i and new[p - 1].base == "u":
            new[p - 1].mod = ""
        if viable(new):
            if not adjacent(st, p):
                st.free_order = True
            st.ls = new
            return True
    return False


WMOD = {"a": "breve", "o": "horn", "u": "horn"}


def try_w(st, cfg, ch, allowed="aou", kind="w", standalone=False):
    if kind in st.escaped:
        return False
    onset, i, j, coda = run_span(st.ls)
    sets = []
    for p in range(i, j - 1):
        if st.ls[p].base == "u" and st.ls[p + 1].base == "o" and "o" in allowed:
            sets.append([p, p + 1])
    for p in range(j - 1, i - 1, -1):
        if st.ls[p].base in allowed:
            sets.append([p])
    has_w = any(st.ls[p].mod in ("horn", "breve") for p in range(i, j))
    for ts in sets:
        if all(st.ls[p].mod == WMOD[st.ls[p].base] for p in ts):
            continue
        new = [x.copy() for x in st.ls]
        for p in ts:
            new[p].mod = WMOD[new[p].base]
            new[p].msrc.append(len(st.raw) - 1)
        if viable(new):
            if not any(adjacent(st, p) for p in ts):
                st.free_order = True
            st.ls = new
            return True
    if has_w:
        # escape: drop w-made letters / mods
        keep = []
        for p, x in enumerate(st.ls):
            if x.fromw:
                continue
            if i <= p < j and x.mod in ("horn", "breve"):
                x.mod = ""
            keep.append(x)
        st.ls = keep
        escape(st, cfg, kind, ch)
        return True
    if standalone and i == j:
        new = st.ls + [L("u", "horn", upper=ch.isupper(), fromw=True, src=len(st.raw) - 1)]
        if viable(new):
            st.ls = new
            return True
    return False


def try_stroke(st, cfg, ch):
    if "stroke" in st.escaped or not st.ls or st.ls[0].base != "d":
        return False
    if st.ls[0].stroke:
        st.ls[0].stroke = False
        escape(st, cfg, "stroke", ch)
        return True
    new = [x.copy() for x in st.ls]
    new[0].stroke = True
    new[0].msrc.append(len(st.raw) - 1)
    if viable(new):
        if len(st.ls) != 1:
            st.free_order = True
        st.ls = new
        return True
    return False


def step(st, cfg, ch):
    st = st.copy()
    st.raw.append(ch)
    if st.literal:
        st.frozen += ch
        return st
    lc = ch.lower()
    done = False
    if cfg.im == "telex":
        if lc in TELEX_TONES:
            done = try_tone(st, cfg, TELEX_TONES[lc], ch)
        elif lc == "z":
            done = try_untone(st, cfg, ch)
        if not done and lc in "aeo":
            done = try_circ(st, cfg, ch, base=lc)
        if not done and lc == "w":
            done = try_w(st, cfg, ch, standalone=cfg.standalone_w)
        if not done and lc == "d":
            done = try_stroke(st, cfg, ch)
        if not done and cfg.brackets and ch in "[]":
            new = st.ls + [L("o" if ch == "[" else "u", "horn", fromw=True)]
            if viable(new):
                st.ls = new
                done = True
    else:
        if ch in VNI_TONES:
            done = try_tone(st, cfg, VNI_TONES[ch], ch)
        elif ch == "0":
            done = try_untone(st, cfg, ch)
        elif ch == "6":
            done = try_circ(st, cfg, ch)
        elif ch == "7":
            done = try_w(st, cfg, ch, allowed="ou", kind="horn")
        elif ch == "8":
            done = try_w(st, cfg, ch, allowed="a", kind="breve")
        elif ch == "9":
            done = try_stroke(st, cfg, ch)
    if not done:
        append_letter(st, cfg, ch)
    return st


def compose(keys, cfg):
    """A space commits the word (kept as composed, ENG-R532 spelling); a Backspace with no active
    token deletes the space and re-opens the word as the commit left it (ENG-R1002). The restore
    decisions of section 8 are not modelled here (boundary.py)."""
    st = St()
    history = []
    for ch in keys:
        if ch == "⌫":
            if not st.raw and history:
                st = history.pop()
                continue
            st = backspace(st, cfg)
        elif ch == " ":
            reopened = st.copy()
            reopened.shown = commit(st, cfg)
            history.append(reopened)
            st = St()
        else:
            st = step(st, cfg, ch)
    return st


def mark_keys_going(st, last):
    """ENG-R710: the modifier keys of the deleted letter that go with it. A remaining letter that
    shows its mark, is not the letter of a standalone w or bracket key, and has no mark key outside
    the deleted letter's keeps the newest shared key."""
    needed = set()
    for x in st.ls[:-1]:
        if not (x.mod or x.stroke) or x.fromw:
            continue
        shared = set(x.msrc) & set(last.msrc)
        if shared and not set(x.msrc) - set(last.msrc):
            needed.add(max(shared))
    return set(last.msrc) - needed


def unshown_horn_before_last(st, cfg):
    """ENG-R710: index of the u just before the last letter when it shows no horn: the last letter
    is the circumflex o that replaced the horns (ENG-R533), or a re-opened word shows the commit
    spelling of an open uo pair (ENG-R532)."""
    if len(st.ls) < 2:
        return None
    k = len(st.ls) - 2
    u, o = st.ls[k], st.ls[k + 1]
    onset, i, j, coda = run_span(st.ls)
    if u.base != "u" or o.base != "o" or not (i <= k and k + 1 < j):
        return None
    if o.mod == "circ" and u.mod == "":
        return k
    if st.shown is not None and st.shown != render(st.ls, st.tone, cfg.style):
        return k
    return None


def backspace(st, cfg):
    """spec rule (ENG-R710): remove the key that produced the last visible character, the modifier
    keys that go with it, the horn keys of a u that shows none, and the tone keys if the tone is
    shown on it."""
    if not st.raw:
        return st
    if st.literal:
        return compose(st.raw[:-1], cfg)
    if not st.ls:
        return compose(st.raw[:-1], cfg)
    last = st.ls[-1]
    drop = {last.src} | mark_keys_going(st, last)
    k = unshown_horn_before_last(st, cfg)
    if k is not None:
        drop |= set(st.ls[k].msrc)
    shown = render(st.ls, st.tone, cfg.style)
    from ortho import TONE_MARKS
    if st.tone and unicodedata.normalize("NFD", shown[-1]) != shown[-1].lower() and any(m in unicodedata.normalize("NFD", shown[-1]) for m in TONE_MARKS.values()):
        drop |= set(st.tone_src)
    cand = [key for i, key in enumerate(st.raw) if i not in drop]
    return compose(cand, cfg)


def commit(st, cfg):
    """boundary normalisation: open 'ươ' -> 'uơ'."""
    d = display(st, cfg)
    if st.literal:
        return d
    s = "".join(x.char() for x in norm_letters(st.ls))
    onset, run, coda, rest, i, j = parse(s)
    if run == "ươ" and not coda:
        idx = i
        # replace the ư at idx with u preserving case
        dl = list(d)
        dl[idx] = "U" if dl[idx].isupper() else "u"
        return "".join(dl)
    return d


def t(keys, im="telex", style="old", **kw):
    cfg = Cfg(im, style, **kw)
    return display(compose(list(keys), cfg), cfg)


def tc(keys, im="telex", style="old", **kw):
    cfg = Cfg(im, style, **kw)
    return commit(compose(list(keys), cfg), cfg)
