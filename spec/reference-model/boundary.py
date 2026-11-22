# SPDX-License-Identifier: MPL-2.0
import re, sys; sys.path.insert(0,'.')
from compose import compose, Cfg, commit, display
from ortho import validity, VOWELS, strip
EN = set("""test this these there best max list been text user wifi usb case password traffic boss coffee as is was has its us car did theme does door her post says war two wow ask task zoom more year mother keyboard verbose startup data plans grows www less tomorrow the and you a i cost room tar class app file think tricky answer powwow wade warden""".split())
TECH = {"www","wifi","usb"}
CODE_ONLY = {"tar","sudo","chown"}  # `chown` (keys not English) joined on 18/11/2026 for REG-38
CODE_CAPITALIZED = set()  # the capitalized code-word list (8.2) is empty in the 13.9 fixtures
NOT_ATTESTED = {"dóe","hẻ","dổ","pót","sáy","ửa","tơn","dơn"}
AMBIG = {"as":"vi","is":"en","was":"en","has":"vi","its":"vi","us":"vi","this":"vi","these":"vi","there":"vi","been":"vi","car":"vi","test":"en","best":"en","list":"en","max":"vi","did":"vi","theme":"vi","cost":"en","room":"en"}
def lang_of(out, restored):
    if restored: return "en"
    if any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" for c in out): return "vi"
    if out.lower() in EN and validity(out) is None: return "en"
    return "neutral"
def vowel_groups(text):
    """Maximal runs of vowel letters (ENG-R804 (d))."""
    return len(re.findall(f"[{''.join(VOWELS)}]+", strip(text.lower())))
def decide(keys, cfg, prev="neutral", context="general", vietnamese_text=False, starts_sentence=False):
    st = compose(list(keys), cfg)
    R = "".join(st.raw); C = commit(st, cfg); r = R.lower()
    if C == R: return C, "unchanged"
    if not any(ch in VOWELS for ch in strip(C.lower())) and not st.had_escape:  # ENG-R801: L4 decides an escape
        return C, "kept: no vowel (abbreviation)"
    if st.had_escape:  # rule L4 as amended by the product owner on 17/11/2026 (ENG-R804, REG-37)
        c_english, r_english = C.lower() in EN | TECH, r in EN | TECH
        if c_english and r_english:
            # the keys of C typed alone in the same context; the phrase evidence of ENG-R804 (a) is not modelled
            alone, _ = decide(C, cfg, prev, context, vietnamese_text, starts_sentence)
            if not st.escape_across and prev != "en" and alone != C: return C, "kept: deliberate escape"
            return R, "restored: escaped token, both English"
        if c_english: return C, "kept: escaped form is an English word"
        if r_english: return R, "restored: escaped token, raw is English"
        # REG-40 (product owner, 20/11/2026): R' is R without the key of each `w` doubling.
        R2 = "".join(k for i, k in enumerate(st.raw) if i not in st.w_doublings)
        if R2 != R and R2.lower() in EN | TECH: return R2, "restored: escaped token, keys without the doubled w are English"
        ends_with_escape = st.last_escape == len(st.raw) - 1
        if not st.escape_across and (vowel_groups(C) <= 1 or ends_with_escape): return C, "kept: user escape"
        # the habit (20/11/2026): every `w` doubling removed a standalone `ư`, no `w` key follows it (`www` is no habit)
        # and none is a capital right after a lowercase `w` (Shift for the second key alone is no habit)
        habit = all(st.w_doublings.values()) and not any(
            st.raw[i + 1:i + 2] in (["w"], ["W"]) or (st.raw[i] == "W" and st.raw[i - 1] == "w") for i in st.w_doublings)
        if R2 != R and habit: return R2, "restored: escaped token typed through"
        return R, "restored: escaped token typed through"
    if st.last_removal is not None and st.last_removal == len(st.raw) - 1:
        # rule L4a, decided by the product owner on 18/11/2026 (ENG-R411, REG-39): the last key removed the tone or marks
        return (R, "restored: tone removal, raw is English") if r in EN | TECH else (C, "kept: tone removal")
    v = validity(C)
    if v is None: return R, "restored: invalid syllable"
    code_word = context == "code" and r in CODE_ONLY and not vietnamese_text
    # L9 right after L5 for a code-only word whose keys are not English, before L6 and L7 would keep it (ENG-R801,
    # ENG-R850 as decided by the product owner on 18/11/2026, REG-38): `chown` follows the line as `tar` does.
    if code_word and not starts_sentence and r not in EN and r not in TECH: return R, "restored: code context, tech word"
    if v == "B":
        return (R, "restored: Tier B and raw is English") if r in EN else (C, "kept: Tier B, not English")
    if r not in EN and r not in TECH: return C, "kept: valid, raw not English"
    if C.lower() not in {x for x in []} and strip(C.lower()) and C.lower() in NOT_ATTESTED: return R, "restored: not attested, raw is English"
    if code_word:  # L9 in its place for a code-only word whose keys are English
        if not starts_sentence: return R, "restored: code context, tech word"
        prev = "neutral"  # a capital at a line start opens a new sentence: the English run ends (review, 16/11/2026)
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
# ENG-R850 as amended by the product owner on 16/11/2026: a token starts a sentence, and L9 does not apply to it, when
# it is the first word of its line, its raw keys are in sentence case (first letter uppercase, every other letter
# lowercase, at least two letters), a space commits it and it is not on the capitalized code-word list. Such a token
# is decided by the rules after L9 with the English run of the line before ended. The first word of a line (shared with
# RV5): no token yet on the line and, before it, only spaces and the openers of prose, at most 63 characters.
LINE_OPENERS = set(' "\'\u201c\u2018([-*#>/')
MAX_LINE_OPENERS = 63
def opens_line(characters):
    return len(characters) <= MAX_LINE_OPENERS and all(ch in LINE_OPENERS for ch in characters)
def sentence_case(keys):
    letters = [ch for ch in keys if ch.isalpha()]
    return len(letters) >= 2 and letters[0].isupper() and all(ch.islower() for ch in letters[1:])
# RV5 of ENG-R828 (16/11/2026, REG-36): a code-only word that L9 restored as the first word of its line takes
# its Vietnamese display when the next word is kept by L7 with a Vietnamese-only letter and is committed by a space,
# Return, `,`, `!` or `?`, provided the rules after L9 (as in `general`, with its own window) keep that display and
# exactly one space separates the two words. The case of the word never widens that evidence.
# `line_start_revision` stands for `EngineConfiguration.lineStartRevision`.
LINE_CONFIRMING_KEYS = set(" \n,!?")
def type_run(text, cfg=None, context="general", line_start_revision=True, code_capitalized=CODE_CAPITALIZED):
    """Types `text` from an empty field: runs of ASCII letters are tokens, every other character is a boundary
    (9.2). Returns the field and the reason of the last decided token."""
    cfg = cfg or Cfg()
    pieces, window, line, reason = [], [], [], None
    line_empty, opened, pending = True, "", None  # pending: (piece index, Vietnamese display) of an RV5 candidate
    for token, boundary in re.findall(r"([A-Za-z]*)([^A-Za-z]*)", text):
        if token:
            prev = "en" if run_is_english(window) else "neutral"
            starts_sentence = (line_empty and sentence_case(token) and boundary[:1] == " "
                               and token.lower() not in code_capitalized)
            C, reason = decide(token, cfg, prev, context, in_vietnamese_text(line), starts_sentence)
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
            opened = re.split(r"[\n\t]", boundary)[-1]
            line_empty = opens_line(opened)
        elif boundary and line_empty:
            opened += boundary
            line_empty = opens_line(opened)
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
    ("and\nTar ", "and\nTar ", "restored: English run"),  # the general context keeps the run across Return
    ("chown ", "chơn ", "kept: valid, raw not English"),  # B035r: the general context never reaches L9 (REG-38)
    ("sudo chown ", "sudo chơn ", "kept: valid, raw not English"),
]
# 01-engine.md 13.9 rows B035 to B035e and B035i to B035n and 13.9.1 rows B064a to B064c (Telex, code context, from an
# empty field; the seed tokens `vieejt` and `and` stand for the previous token `vi` and `en`), the sentences of ENG-R850
# (with the sentence condition of 16/11/2026) and the RV5 cases of ENG-R828 (REG-36).
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
    ("vieejt\ntar thuwr ", "việt\ntả thử ", "kept: valid, raw not English"),
    ("and\ntar thuwr ", "and\ntar thử ", "kept: valid, raw not English"),  # L10 would restore `tar`
    ("tar\nthuwr ", "tar\nthử ", "kept: valid, raw not English"),  # a one-word line
    ("Tar thuwr tar ", "Tả thử tả ", "kept: default vi"),
    # The first word of a line after spaces and the openers of prose (review of 16/11/2026, ENG-R850 (d)).
    (" tar thuwr ", " tả thử ", "kept: valid, raw not English"),
    ("- tar thuwr ", "- tả thử ", "kept: valid, raw not English"),
    ('"tar thuwr ', '"tả thử ', "kept: valid, raw not English"),
    ("| tar thuwr ", "| tar thử ", "kept: valid, raw not English"),
    ("./tar thuwr ", "./tar thử ", "kept: valid, raw not English"),
    # The sentence condition of L9 (ENG-R850, product owner, 16/11/2026): decided at the word's own commit.
    ("Tar ", "Tả ", "kept: default vi"),  # B035m
    ('Tar-', 'Tar-', "restored: code context, tech word"),  # B064c
    ("Tar anh ", "Tả anh ", "unchanged"),
    ("Tar thuwr.", "Tả thử.", "kept: valid, raw not English"),
    ("Tar anh.", "Tả anh.", "unchanged"),
    ("Tar test ", "Tả test ", "restored: ambiguity table en"),  # the cost: an English line typed with a capital
    ("Tar anh-", "Tả anh-", "unchanged"),
    ("Tar thuwr\t", "Tả thử\t", "kept: valid, raw not English"),
    ("vieejt\nTar ", "việt\nTả ", "kept: default vi"),
    ("Tar\n", "Tar\n", "restored: code context, tech word"),
    ("Tar.", "Tar.", "restored: code context, tech word"),
    ("Tar:", "Tar:", "restored: code context, tech word"),
    (" Tar ", " Tả ", "kept: default vi"),  # an indent before it
    ("    Tar ", "    Tả ", "kept: default vi"),
    ('"Tar ', '"Tả ', "kept: default vi"),  # a quote before it
    ("(Tar ", "(Tả ", "kept: default vi"),
    ("- Tar ", "- Tả ", "kept: default vi"),  # a list marker
    ("# Tar ", "# Tả ", "kept: default vi"),  # a heading or comment marker
    ("// Tar ", "// Tả ", "kept: default vi"),
    ("vieejt\n> Tar ", "việt\n> Tả ", "kept: default vi"),
    (" " * 63 + "Tar ", " " * 63 + "Tả ", "kept: default vi"),
    (" " * 64 + "Tar ", " " * 64 + "Tar ", "restored: code context, tech word"),  # the bounded walk
    ("| Tar ", "| Tar ", "restored: code context, tech word"),  # a code character
    ("./Tar ", "./Tar ", "restored: code context, tech word"),  # a path
    ("1. Tar ", "1. Tar ", "restored: code context, tech word"),  # a number
    ("\u00a0Tar ", "\u00a0Tar ", "restored: code context, tech word"),  # a no-break space
    # A capital at a line start opens a new sentence, so the English run of the line before ends (ENG-R823).
    ("and\nTar ", "and\nTả ", "kept: default vi"),
    ("and\nTar thuwr cais nayf ", "and\nTả thử cái này ", "kept: valid, raw not English"),
    ("and\nTAR thuwr ", "and\nTAR thử ", "kept: valid, raw not English"),
    ("sudo Tar ", "sudo Tar ", "restored: code context, tech word"),
    ("TAr ", "TAr ", "restored: code context, tech word"),  # not sentence case
    ("TAR anh ", "TAR anh ", "unchanged"),
    ("TAR thuwr ", "TẢ thử ", "kept: valid, raw not English"),  # B035n: all caps keeps L9, then RV5
    ("TAR thuwr.", "TAR thử.", "kept: valid, raw not English"),
    # L9 right after L5 (product owner, 18/11/2026, REG-38): a code-only word whose keys are not English follows the line.
    ("chown ", "chown ", "restored: code context, tech word"),  # B035o
    ("sudo chown ", "sudo chown ", "restored: code context, tech word"),  # B035p
    ("vieejt chown ", "việt chơn ", "kept: valid, raw not English"),  # B035q
    ("Chown ", "Chơn ", "kept: valid, raw not English"),  # B035s
    ("chown thuwr ", "chơn thử ", "kept: valid, raw not English"),  # B035t, RV5
    ("ls; chown ", "ls; chown ", "restored: code context, tech word"),
    ("and chown ", "and chown ", "restored: code context, tech word"),
    ("tay chown ", "tay chơn ", "kept: valid, raw not English"),
    ("chown xf ", "chown xf ", "unchanged"),
    ("Chown-", "Chown-", "restored: code context, tech word"),
]
# RV5 with `lineStartRevision` off (D29 off): a lowercase or all-caps word keeps the keys; the sentence condition of L9
# does not depend on the switch.
CODE_RUNS_WITHOUT_LINE_REVISION = [
    ("Tar thuwr ", "Tả thử ", "kept: valid, raw not English"),
    ("Tar thuwr cais nayf ", "Tả thử cái này ", "kept: valid, raw not English"),
    ("tar thuwr ", "tar thử ", "kept: valid, raw not English"),
    ("TAR thuwr ", "TAR thử ", "kept: valid, raw not English"),
    ("chown thuwr ", "chown thử ", "kept: valid, raw not English"),
]
# The capitalized code-word list (`host` in the bundled data) with `tar` on it, standing for `host`: the word keeps L9
# in sentence case too, and RV5 with its own evidence (`Host minh` keeps the keys, `Host nayf` gives `Hót này`).
CODE_RUNS_CAPITALIZED = [
    ("Tar ", "Tar ", "restored: code context, tech word"),
    ("Tar anh ", "Tar anh ", "unchanged"),
    ("Tar thuwr ", "Tả thử ", "kept: valid, raw not English"),
    ("Tar thuwr.", "Tar thử.", "kept: valid, raw not English"),
    ("tar thuwr ", "tả thử ", "kept: valid, raw not English"),
    ("and\nTar ", "and\nTar ", "restored: code context, tech word"),
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
# Rule L4 as amended on 17/11/2026 (ENG-R804, REG-37) with the 13.9 fixtures, where no escaped form and its keys are
# both English (case (a) is checked by the engine's EscapeCommitTests and the rows of 13.9.5).
ESCAPE_RUNS = [
    ("leecher ", "leecher ", "restored: escaped token typed through"),
    ("cookout ", "cookout ", "restored: escaped token typed through"),
    ("coffeehouse ", "coffeehouse ", "restored: escaped token typed through"),
    ("pajama ", "pajama ", "restored: escaped token typed through"),
    ("costs ", "costs ", "restored: escaped token typed through"),
    ("current ", "current ", "restored: escaped token typed through"),
    ("boooong ", "booong ", "kept: user escape"),
    ("thesee ", "thée ", "kept: user escape"),
    ("theesee ", "theesee ", "restored: escaped token typed through"),  # known cost: the tone key breaks the doubling
    ("beefer ", "beefer ", "restored: escaped token typed through"),
    ("nhaamff ", "nhâmf ", "kept: user escape"),
    ("Kroong Anaa ", "Krông Ana ", "kept: user escape"),
    ("ass ", "as ", "kept: escaped form is an English word"),
    ("tarr ", "tar ", "kept: escaped form is an English word"),
    ("password ", "password ", "restored: escaped token, raw is English"),
    ("www ", "www ", "restored: escaped token, raw is English"),
    # REG-40 (product owner, 20/11/2026): a `w` doubled out of habit is left out of the restore (`answer` and `powwow`
    # added to the fixture lexicon below).
    ("wwebview ", "webview ", "restored: escaped token typed through"),
    ("Wwebview ", "Webview ", "restored: escaped token typed through"),
    ("Twwitter ", "Twitter ", "restored: escaped token typed through"),
    ("answwer ", "answer ", "restored: escaped token, keys without the doubled w are English"),
    ("bowwow ", "bowwow ", "restored: escaped token typed through"),  # a horn doubling: R
    ("powwow ", "powwow ", "restored: escaped token, raw is English"),
    ("ww ", "w ", "kept: user escape"),
    ("uww ", "uw ", "kept: user escape"),
    ("wwwexample ", "wwwexample ", "restored: escaped token typed through"),  # a `w` follows the doubling: R
    ("wWEBVIEW ", "wWEBVIEW ", "restored: escaped token typed through"),  # a capital after a lowercase `w`: R
    ("WWEBVIEW ", "WEBVIEW ", "restored: escaped token typed through"),
    # REG-41 (product owner, 22/11/2026, ADR 0010 item 8): the escaped letter of a standalone `w` doubling is a capital
    # when either `w` key is, so `C` keeps the capital (`wade` and `warden` added to the fixture lexicon above).
    ("Wwade ", "Wade ", "kept: escaped form is an English word"),
    ("Wwarden ", "Warden ", "kept: escaped form is an English word"),
    ("Wwar ", "War ", "kept: escaped form is an English word"),
    ("Wwatt ", "Watt ", "kept: user escape"),
    ("Ww ", "W ", "kept: user escape"),
    ("WWade ", "Wade ", "kept: escaped form is an English word"),
    ("wwade ", "wade ", "kept: escaped form is an English word"),
    ("Www ", "Www ", "restored: escaped token, raw is English"),
    ("Uww ", "Uw ", "kept: user escape"),  # a horn doubling keeps the case of its own key
]
# Rule L4a (product owner, 18/11/2026, ENG-R411, REG-39) with the 13.9 fixtures: a token whose last key removed the tone
# or the marks keeps the text shown unless its keys are English; a removal that more letters follow is decided as before.
REMOVAL_RUNS = [
    ("dduwowngfzz ", "duong ", "kept: tone removal"),  # B052a
    ("vieejtz ", "viêt ", "kept: tone removal"),  # B052b
    ("daauszz ", "dau ", "kept: tone removal"),  # B052c
    ("vieejtzz ", "viet ", "kept: tone removal"),
    ("testz ", "tet ", "kept: tone removal"),
    ("daauszzz ", "daauszzz ", "restored: invalid syllable"),  # the third `z` is a letter
    ("Amazon ", "Amazon ", "restored: invalid syllable"),  # a removal that more letters follow
    ("vieejtzs ", "viết ", "kept: valid, raw not English"),
    ("aazaa ", "aa ", "kept: user escape"),  # an escape in the token: L4 decides
]
# VNI rows, decided token by token (`type_run` splits on digits): B052d.
REMOVAL_VNI = [("vie65t0", "viêt", "kept: tone removal"), ("vie65t00", "viet", "kept: tone removal")]
if __name__ == "__main__":
    bad = [(keys, type_run(keys), (want, why)) for keys, want, why in RUNS if type_run(keys) != (want, why)]
    bad += [(keys, type_run(keys), (want, why)) for keys, want, why in ESCAPE_RUNS if type_run(keys) != (want, why)]
    bad += [(keys, type_run(keys), (want, why)) for keys, want, why in REMOVAL_RUNS if type_run(keys) != (want, why)]
    bad += [(keys, decide(keys, Cfg(im="vni")), (want, why)) for keys, want, why in REMOVAL_VNI
            if decide(keys, Cfg(im="vni")) != (want, why)]
    bad += [(keys, type_run_collision(keys), (want, why)) for keys, want, why in COLLISION_RUNS
            if type_run_collision(keys) != (want, why)]
    bad += [(keys, type_run(keys, context="code"), (want, why)) for keys, want, why in CODE_RUNS
            if type_run(keys, context="code") != (want, why)]
    bad += [(keys, type_run(keys, context="code", line_start_revision=False), (want, why))
            for keys, want, why in CODE_RUNS_WITHOUT_LINE_REVISION
            if type_run(keys, context="code", line_start_revision=False) != (want, why)]
    bad += [(keys, type_run(keys, context="code", code_capitalized={"tar"}), (want, why))
            for keys, want, why in CODE_RUNS_CAPITALIZED
            if type_run(keys, context="code", code_capitalized={"tar"}) != (want, why)]
    for row in bad: print("mismatch:", row)
    total = (len(RUNS) + len(ESCAPE_RUNS) + len(REMOVAL_RUNS) + len(REMOVAL_VNI) + len(COLLISION_RUNS) + len(CODE_RUNS) + len(CODE_RUNS_WITHOUT_LINE_REVISION)
             + len(CODE_RUNS_CAPITALIZED))
    print(f"{total - len(bad)}/{total} English-run, escape, tone-removal, collision and code-context examples agree")
    sys.exit(1 if bad else 0)
