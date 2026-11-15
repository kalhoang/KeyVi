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
        self.mark_rm = []  # tone-removal keys that removed letter marks (ENG-R411)
        self.lit_start = None  # raw index of the key that started literal mode
        self.lit_undone = None  # that key was an escape: the keys it undid (ENG-R711)
        self.shown = None  # re-opened word: the text the commit left on screen (ENG-R1002)

    def copy(self):
        n = St()
        n.ls = [x.copy() for x in self.ls]
        n.tone, n.literal, n.frozen = self.tone, self.literal, self.frozen
        n.escaped = set(self.escaped)
        n.raw = list(self.raw)
        n.free_order, n.had_escape = self.free_order, self.had_escape
        n.tone_src = list(self.tone_src)
        n.mark_rm = list(self.mark_rm)
        n.lit_start = self.lit_start
        n.lit_undone = None if self.lit_undone is None else set(self.lit_undone)
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
    st.lit_start = len(st.raw) - 1


def append_letter(st, cfg, ch):
    """append a plain letter (or literal char); enter literal mode if not viable."""
    lc = ch.lower()
    if lc.isascii() and lc.isalpha():
        cand = st.ls + [L(lc, upper=ch.isupper(), src=len(st.raw) - 1)]
        if viable(cand):
            st.ls = cand
            return
    freeze_with(st, cfg, ch)


def escape(st, cfg, kind, ch, undone=()):
    """4.7; `undone` are the keys whose effect the escape removed (ENG-R711)."""
    st.escaped.add(kind)
    st.had_escape = True
    n = len(st.ls)
    append_letter(st, cfg, ch)
    if len(st.ls) > n:
        st.ls[-1].undone = list(undone)
    else:
        st.lit_undone = set(undone)


def try_tone(st, cfg, t, ch):
    onset, i, j, coda = run_span(st.ls)
    if i == j or "tone" in st.escaped:
        return False
    st.tone_src.append(len(st.raw) - 1)
    if st.tone == t:
        st.tone = 0
        escape(st, cfg, "tone", ch, st.tone_src[:-1])
        return True
    st.tone = t
    return True


def try_untone(st, cfg, ch):
    """ENG-R411, one layer per press: the tone, else every vowel mark and the stroke, else nothing."""
    if "tone" in st.escaped:
        return False
    if st.tone:
        st.tone = 0
        st.tone_src.append(len(st.raw) - 1)
        return True
    if not any(x.mod or x.stroke for x in st.ls):
        return False
    for x in st.ls:
        x.mod, x.stroke = "", False
    st.mark_rm.append(len(st.raw) - 1)
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
            undone = list(st.ls[p].msrc)
            if st.ls[p].base == "o" and p - 1 >= i and st.ls[p - 1].base == "u" and not st.ls[p - 1].mod:
                undone += st.ls[p - 1].msrc  # the horn the circumflex removed (ENG-R533)
            st.ls[p].mod = ""
            escape(st, cfg, "circ", ch, undone)
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
        undone = []
        for p, x in enumerate(st.ls):
            if x.fromw:
                undone += [x.src] + x.msrc
                continue
            if i <= p < j and x.mod in ("horn", "breve"):
                x.mod = ""
                undone += x.msrc
            keep.append(x)
        st.ls = keep
        escape(st, cfg, kind, ch, undone)
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
        escape(st, cfg, "stroke", ch, st.ls[0].msrc)
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
    return step_ex(st, cfg, ch)[0]


def step_ex(st, cfg, ch):
    """One key; also returns whether it acted by its transform role (not as a letter or literal)."""
    st = st.copy()
    st.raw.append(ch)
    if st.literal:
        st.frozen += ch
        return st, False
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
    return st, done


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
    the deleted letter's keeps the newest shared key. A mark removal clears every mark (ENG-R411), so
    only the mark keys after the newest removal count, and a standalone w or bracket letter typed
    before it no longer carries its own mark."""
    last_rm = max(st.mark_rm, default=-1)
    needed = set()
    for x in st.ls[:-1]:
        if not (x.mod or x.stroke):
            continue
        if x.fromw and not (0 <= x.src < last_rm):
            continue
        shown = {k for k in x.msrc if k > last_rm}
        shared = shown & set(last.msrc)
        if shared and not shown - set(last.msrc):
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


def replay_without(st, drop, cfg, plain=None):
    """ENG-R710, ENG-R711: replay the raw keys not in `drop`. A mark removal is left out when it would
    now be a letter; a key that set or removed the tone and finds no vowel yet waits and is tried again,
    in order, after each later letter (ENG-R432), and is left out if none takes it. Keys in `plain`
    replay as the given letter (ENG-R711 fallback)."""
    plain = plain or {}
    idle = set(st.mark_rm)
    chain = set(st.tone_src)
    new = St()
    waiting = []
    for i, key in enumerate(st.raw):
        if i in drop:
            continue
        if i in plain:
            key = plain[i]
        if i in idle or i in chain:
            trial, done = step_ex(new, cfg, key)
            if done:
                new = trial
            elif i in chain:
                waiting.append(key)
            continue
        new = step(new, cfg, key)
        still = []
        for w in waiting:
            trial, done = step_ex(new, cfg, w)
            if done:
                new = trial
            else:
                still.append(w)
        waiting = still
    return new


MARK_KEYS = {"telex": {"circ": None, "horn": "w", "breve": "w"}, "vni": {"circ": "6", "horn": "7", "breve": "8"}}
TONE_KEYS = {"telex": "sfrxj", "vni": "12345"}


def retype(st, cfg, letters, expected):
    """ENG-R711 fallback 2: type the letters shown one at a time, each mark key right after its letter,
    the tone key after the letter that gives `expected`, tried from the last letter back."""
    keys, ends = [], []
    for x in letters:
        keys.append(x.base.upper() if x.upper else x.base)
        if x.mod:
            mk = MARK_KEYS[cfg.im][x.mod]
            keys.append(mk if mk else x.base)
        if x.stroke:
            keys.append("d" if cfg.im == "telex" else "9")
        ends.append(len(keys))
    tries = [keys] if not st.tone else [keys[:e] + [TONE_KEYS[cfg.im][st.tone - 1]] + keys[e:] for e in reversed(ends)]
    for k in tries:
        cand = compose(k, cfg)
        if display(cand, cfg) == expected:
            return cand
    return None


def escape_backspace(st, cfg, drop):
    """ENG-R711: the escape letter goes with the keys it undid; the result is the old display minus its
    last character, with the fallbacks: a standalone-w letter shown plain kept as a plain key, then the
    letters shown retyped."""
    expected = display(st, cfg)[:-1]
    cand = replay_without(st, drop, cfg)
    if display(cand, cfg) == expected:
        return cand
    plain = {x.src: (x.base.upper() if x.upper else x.base)
             for x in st.ls if x.fromw and x.src >= 0 and x.base in "uo" and not x.mod}
    if plain:
        alt = replay_without(st, drop, cfg, plain)
        if display(alt, cfg) == expected:
            return alt
    letters = st.ls if st.literal else st.ls[:-1]
    return retype(st, cfg, letters, expected) or cand


def backspace(st, cfg):
    """spec rule (ENG-R710): remove the key that produced the last visible character, the modifier
    keys that go with it, the horn keys of a u that shows none, and the tone keys if the tone is
    shown on it; an escape letter takes the keys it undid (ENG-R711)."""
    if not st.raw:
        return st
    if st.literal:
        last = len(st.raw) - 1
        if st.lit_start == last and st.lit_undone is not None:
            return escape_backspace(st, cfg, {last} | st.lit_undone)
        return compose(st.raw[:-1], cfg)
    if not st.ls:
        return compose(st.raw[:-1], cfg)
    last = st.ls[-1]
    drop = {last.src} | set(last.undone) | mark_keys_going(st, last)
    k = unshown_horn_before_last(st, cfg)
    if k is not None:
        drop |= set(st.ls[k].msrc)
    shown = render(st.ls, st.tone, cfg.style)
    from ortho import TONE_MARKS
    if st.tone and unicodedata.normalize("NFD", shown[-1]) != shown[-1].lower() and any(m in unicodedata.normalize("NFD", shown[-1]) for m in TONE_MARKS.values()):
        drop |= set(st.tone_src)
    if last.undone:
        return escape_backspace(st, cfg, drop)
    return replay_without(st, drop, cfg)


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
