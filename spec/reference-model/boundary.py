# SPDX-License-Identifier: MPL-2.0
import re, sys; sys.path.insert(0,'.')
from compose import compose, Cfg, commit, display
from ortho import validity, VOWELS, strip
EN = set("""test this these there best max list been text user wifi usb case password traffic boss coffee as is was has its us car did theme does door her post says war two wow ask task zoom more year mother keyboard verbose startup data plans grows www less tomorrow the and you a i cost room tar class app file think tricky""".split())
TECH = {"www","wifi","usb"}
CODE_ONLY = {"tar","sudo"}
NOT_ATTESTED = {"dóe","hẻ","dổ","pót","sáy","ửa","tơn","dơn"}
AMBIG = {"as":"vi","is":"en","was":"en","has":"vi","its":"vi","us":"vi","this":"vi","these":"vi","there":"vi","been":"vi","car":"vi","test":"en","best":"en","list":"en","max":"vi","did":"vi","theme":"vi","cost":"en","room":"en"}
def lang_of(out, restored):
    if restored: return "en"
    if any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" for c in out): return "vi"
    if out.lower() in EN and validity(out) is None: return "en"
    return "neutral"
def decide(keys, cfg, prev="neutral", context="general", vietnamese_text=False):
    st = compose(list(keys), cfg)
    R = "".join(st.raw); C = commit(st, cfg); r = R.lower()
    if C == R: return C, "unchanged"
    if not any(ch in VOWELS for ch in strip(C.lower())): return C, "kept: no vowel (abbreviation)"
    if st.had_escape:
        if C.lower() in EN: return C, "kept: escaped form is an English word"
        if r in EN: return R, "restored: escaped token, raw is English"
        return C, "kept: user escape"
    v = validity(C)
    if v is None: return R, "restored: invalid syllable"
    if v == "B":
        return (R, "restored: Tier B and raw is English") if r in EN else (C, "kept: Tier B, not English")
    if r not in EN and r not in TECH: return C, "kept: valid, raw not English"
    if C.lower() not in {x for x in []} and strip(C.lower()) and C.lower() in NOT_ATTESTED: return R, "restored: not attested, raw is English"
    if context == "code" and r in CODE_ONLY and not vietnamese_text: return R, "restored: code context, tech word"
    if prev == "en": return R, "restored: English run"
    d = AMBIG.get(r, "vi")
    return (R, "restored: ambiguity table en") if d == "en" else (C, "kept: ambiguity table vi" if r in AMBIG else "kept: default vi")

# ENG-R823 as amended by the product owner on 14/11/2026 (REG-32): the language of a committed token, first
# match wins, and the window rule of the English run.
def lang_of_decision(out, reason):
    if reason.startswith("restored"): return "en"
    if reason in ("kept: ambiguity table vi", "kept: default vi"): return "neutral"  # kept by L11: no evidence
    return lang_of(out, False)
def run_is_english(window):
    last = window[-3:]
    return "en" in last and "vi" not in last
# ENG-R850 as amended on 15/11/2026 (REG-35): rule L9 restores a code-only word only outside Vietnamese text. The
# line is the history: it starts empty and Return, Tab and a reset clear it. Each entry of `line` is (language, a
# Vietnamese syllable typed unchanged, a code-only word shown as typed, code character after it, no space after it:
# the next word is glued to it, a code join such as `anh.tar.gz` or `minh@host`).
CODE_CHARACTERS = set("`|&$")
SPACES = set(" \u00a0")
def vietnamese_as_typed(keys, C, reason):
    return (reason == "unchanged" and validity(C) == "A" and keys.lower() not in EN and keys.lower() not in TECH
            and len(keys) >= 2 and keys.isalpha() and not (keys.isupper() and len(keys) > 1))
def in_vietnamese_text(line):
    if not line: return False
    language, _, code_word, code_after, joined = line[-1]
    if language == "en" or code_word or code_after or joined: return False
    return any(lang == "vi" or as_typed for lang, as_typed, _, _, _ in line[-3:])
# RV5 of ENG-R828 (16/11/2026, REG-36): a code-only word that L9 restored as the first thing typed on its line takes
# its Vietnamese display when the next word is kept by L7 with a Vietnamese-only letter and is committed by a space,
# Return, `,`, `!` or `?`, provided the rules after L9 (as in `general`, with its own window) keep that display and
# exactly one space separates the two words. `line_start_revision` stands for `EngineConfiguration.lineStartRevision`.
LINE_CONFIRMING_KEYS = set(" \n,!?")
def type_run(text, cfg=None, context="general", line_start_revision=True):
    """Types `text` from an empty field: runs of ASCII letters are tokens, every other character is a boundary
    (9.2). Returns the field and the reason of the last decided token."""
    cfg = cfg or Cfg()
    pieces, window, line, reason = [], [], [], None
    line_empty, pending = True, None  # pending: (piece index, Vietnamese display) of an RV5 candidate
    for token, boundary in re.findall(r"([A-Za-z]*)([^A-Za-z]*)", text):
        if token:
            prev = "en" if run_is_english(window) else "neutral"
            C, reason = decide(token, cfg, prev, context, in_vietnamese_text(line))
            window.append(lang_of_decision(C, reason))
            if (pending and reason == "kept: valid, raw not English" and window[-1] == "vi" and boundary
                    and boundary[0] in LINE_CONFIRMING_KEYS):
                pieces[pending[0]] = pending[1]  # RV5: the word takes its Vietnamese display
                window[-2] = "neutral"
                line[-1] = ("neutral",) + line[-1][1:2] + (False,) + line[-1][3:]
            pending = None
            shown_as_typed = reason == "unchanged" or reason.startswith("restored")
            line.append((window[-1], vietnamese_as_typed(token, C, reason),
                         shown_as_typed and token.lower() in CODE_ONLY, False, False))
            if (line_start_revision and line_empty and reason == "restored: code context, tech word"
                    and boundary == " "):
                general = decide(token, cfg, prev, context, vietnamese_text=True)
                if not general[1].startswith("restored"):
                    pending = (len(pieces), general[0])
            pieces.append(C)
            line_empty = False
        if line and token:
            line[-1] = line[-1][:3] + (any(ch in CODE_CHARACTERS for ch in boundary),
                                       not any(ch in SPACES for ch in boundary))
        if "\n" in boundary or "\t" in boundary:
            line = []
            line_empty = re.split(r"[\n\t]", boundary)[-1] == ""
        elif boundary:
            line_empty = False
        pieces.append(boundary)
    return "".join(pieces), reason
# 01-engine.md 13.9.2 (B065-B072) and the sentences of ENG-R823, with the 13.9 fixtures above.
RUNS = [
    ("Khusc caif cacs app caafn thieest treen win cungx tricky as.", "Khúc cài các app cần thiết trên win cũng tricky á.", "kept: ambiguity table vi"),
    ("dduwowcj as.", "được á.", "kept: ambiguity table vi"),
    ("treen server been ", "trên server bên ", "kept: ambiguity table vi"),
    ("guwir file car ", "gửi file cả ", "kept: ambiguity table vi"),
    ("this is the best car ", "thí is the best car ", "restored: English run"),
    ("I think this is as good as ", "I think this is as good as ", "restored: English run"),
    ("This is as ", "Thí is as ", "restored: English run"),
    ("tricky as ", "tricky as ", "restored: English run"),
    ("treen server been kia ", "trên server bên kia ", "unchanged"),
    ("I think this is as good as it gets ", "I think this is as good as it gets ", "unchanged"),
    ("This is as good ", "Thí is as good ", "restored: invalid syllable"),
    ("tricky as hell ", "tricky as hell ", "unchanged"),
    ("tooi nghix the best car ", "tôi nghĩ the best cả ", "kept: ambiguity table vi"),  # the known cost
    ("vieejt and nam this as ", "việt and nam thí as ", "restored: English run"),  # the second known cost
]
# 01-engine.md 13.9 rows B035 to B035e and B035i to B035l and 13.9.1 rows B064a and B064b (Telex, code context, from an
# empty field; the seed tokens `vieejt` and `and` stand for the previous token `vi` and `en`), the sentences of ENG-R850
# and the RV5 cases of ENG-R828 (REG-36).
CODE_RUNS = [
    ("tar ", "tar ", "restored: code context, tech word"),
    ("vieejt tar ", "việt tả ", "kept: default vi"),
    ("and tar ", "and tar ", "restored: code context, tech word"),
    ("chinhs tar ", "chính tả ", "kept: default vi"),
    ("moo tar ", "mô tả ", "kept: default vi"),
    ("sudo tar ", "sudo tar ", "restored: code context, tech word"),
    ('Suwar looxi chinhs tar"', 'Sửa lỗi chính tả"', "kept: default vi"),
    ('tar"', 'tar"', "restored: code context, tech word"),
    ("anh tar ", "anh tả ", "kept: default vi"),
    ("vieejt\ntar ", "việt\ntar ", "restored: code context, tech word"),
    ("dungf `tar`", "dùng `tar`", "restored: code context, tech word"),
    ('echo "xin chaof" | tar ', 'echo "xin chào" | tar ', "restored: code context, tech word"),
    ("vieejt (tar)", "việt (tả)", "kept: default vi"),
    ("vieejt a a a tar ", "việt a a a tar ", "restored: code context, tech word"),
    ("anh.tar ", "anh.tar ", "restored: code context, tech word"),
    ("anh@tar ", "anh@tar ", "restored: code context, tech word"),
    ("vieejt anh/tar ", "việt anh/tar ", "restored: code context, tech word"),
    ("vieejt. tar ", "việt. tả ", "kept: default vi"),
    ("vieejt; tar ", "việt; tả ", "kept: default vi"),
    ("Tar thuwr ", "Tả thử ", "kept: valid, raw not English"),  # B035j, RV5
    ("tar xf ", "tar xf ", "unchanged"),  # B035k
    ("tar nhaatj-kys ", "tar nhật-ký ", "kept: valid, raw not English"),  # B035l
    ("Tar thuwr cais nayf ", "Tả thử cái này ", "kept: valid, raw not English"),  # REG-36
    ("tar thuwr\n", "tả thử\n", "kept: valid, raw not English"),
    ("tar thuwr,", "tả thử,", "kept: valid, raw not English"),
    ("tar thuwr.", "tar thử.", "kept: valid, raw not English"),
    ("tar thuwr\t", "tar thử\t", "kept: valid, raw not English"),
    ("tar nhaatj.log ", "tar nhật.log ", "unchanged"),
    ("tar anh ", "tar anh ", "unchanged"),
    ("tar  thuwr ", "tar  thử ", "kept: valid, raw not English"),
    ("sudo tar thuwr ", "sudo tar thử ", "kept: valid, raw not English"),
    (" tar thuwr ", " tar thử ", "kept: valid, raw not English"),
    ("vieejt\ntar thuwr ", "việt\ntả thử ", "kept: valid, raw not English"),
    ("and\ntar thuwr ", "and\ntar thử ", "kept: valid, raw not English"),  # L10 would restore `tar`
    ("tar\nthuwr ", "tar\nthử ", "kept: valid, raw not English"),  # a one-word line
    ("Tar thuwr tar ", "Tả thử tả ", "kept: default vi"),
]
# RV5 with `lineStartRevision` off (D29 off): the word keeps the keys.
CODE_RUNS_WITHOUT_LINE_REVISION = [
    ("Tar thuwr ", "Tar thử ", "kept: valid, raw not English"),
    ("Tar thuwr cais nayf ", "Tar thử cái này ", "kept: valid, raw not English"),
]
# Collision rules at commit (15/11/2026): L9a boundary particle (ENG-R825), L9b phrase looking back (ENG-R826), the
# `run: vi` exemption of L10 and the English-lean window (ENG-R823, ENG-R827), with small fixture lists on top of the
# 13.9 fixtures. The revisions of ENG-R828 are not modelled; the rows below have none. The engine test
# `CollisionCommitRuleTests.referenceModelRows` types the same rows with the same lists.
PARTICLES = {"as"}
PHRASES = {("has", "been"), ("this", "is"), ("such", "as"), ("as", "good", "as")}
RUN_EXEMPT = {"theme"}
LEAN = {"the", "i"}
def decide_collision(keys, cfg, window, boundary, chain):
    C, reason = decide(keys, cfg, "neutral")
    R = "".join(compose(list(keys), cfg).raw); r = R.lower()
    if reason not in ("kept: ambiguity table vi", "kept: default vi", "restored: ambiguity table en"):
        return C, reason
    phrase = any(len(chain) >= p and m[:p + 1] == tuple(chain[-p:]) + (r,) for p in (1, 2, 3) for m in PHRASES)
    if r in PARTICLES and boundary and boundary[0] in ".!?\n" and not phrase: return C, "kept: boundary particle"
    if phrase: return R, "restored: phrase"
    if run_is_english(window) and r not in RUN_EXEMPT: return R, "restored: English run"
    return C, reason
def lang_of_collision(out, reason, keys):
    if reason == "kept: boundary particle": return "neutral"
    if reason == "unchanged" and keys.lower() in LEAN: return "en"
    return lang_of_decision(out, reason)
def type_run_collision(text, cfg=None):
    """`type_run` with the collision rules at commit; a phrase chain needs exactly one space after each token."""
    cfg = cfg or Cfg()
    out, window, chain, reason = "", [], [], None
    for token, boundary in re.findall(r"([A-Za-z]*)([^A-Za-z]*)", text):
        if token:
            C, reason = decide_collision(token, cfg, window, boundary, chain)
            window.append(lang_of_collision(C, reason, token))
            chain = chain + [token.lower()] if boundary == " " else []
            out += C
        out += boundary
    return out, reason
COLLISION_RUNS = [
    ("tricky as.", "tricky á.", "kept: boundary particle"),
    ("tricky as ", "tricky as ", "restored: English run"),
    ("tricky as. car ", "tricky á. car ", "restored: English run"),
    ("and has been ", "and has been ", "restored: phrase"),
    ("tricky theme ", "tricky thêm ", "kept: ambiguity table vi"),
    ("the car ", "the car ", "restored: English run"),
    ("I car ", "I car ", "restored: English run"),
    ("tricky such as ", "tricky such as ", "restored: phrase"),
    ("dduwowcj such as.", "được such as.", "restored: phrase"),
]
if __name__ == "__main__":
    bad = [(keys, type_run(keys), (want, why)) for keys, want, why in RUNS if type_run(keys) != (want, why)]
    bad += [(keys, type_run_collision(keys), (want, why)) for keys, want, why in COLLISION_RUNS
            if type_run_collision(keys) != (want, why)]
    bad += [(keys, type_run(keys, context="code"), (want, why)) for keys, want, why in CODE_RUNS
            if type_run(keys, context="code") != (want, why)]
    bad += [(keys, type_run(keys, context="code", line_start_revision=False), (want, why))
            for keys, want, why in CODE_RUNS_WITHOUT_LINE_REVISION
            if type_run(keys, context="code", line_start_revision=False) != (want, why)]
    for row in bad: print("mismatch:", row)
    total = len(RUNS) + len(COLLISION_RUNS) + len(CODE_RUNS) + len(CODE_RUNS_WITHOUT_LINE_REVISION)
    print(f"{total - len(bad)}/{total} English-run, collision and code-context examples agree")
    sys.exit(1 if bad else 0)
