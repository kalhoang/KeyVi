# SPDX-License-Identifier: MPL-2.0
import re, sys; sys.path.insert(0,'.')
from compose import compose, Cfg, commit, display
from ortho import validity, VOWELS, strip
EN = set("""test this these there best max list been text user wifi usb case password traffic boss coffee as is was has its us car did theme does door her post says war two wow ask task zoom more year mother keyboard verbose startup data plans grows www less tomorrow the and you a i cost room tar class app file think tricky""".split())
TECH = {"www","wifi","usb","tar"}
NOT_ATTESTED = {"dóe","hẻ","dổ","pót","sáy","ửa","tơn","dơn"}
AMBIG = {"as":"vi","is":"en","was":"en","has":"vi","its":"vi","us":"vi","this":"vi","these":"vi","there":"vi","been":"vi","car":"vi","test":"en","best":"en","list":"en","max":"vi","did":"vi","theme":"vi","cost":"en","room":"en"}
def lang_of(out, restored):
    if restored: return "en"
    if any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" for c in out): return "vi"
    if out.lower() in EN and validity(out) is None: return "en"
    return "neutral"
def decide(keys, cfg, prev="neutral", context="general"):
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
    if context == "code" and r in TECH: return R, "restored: code context, tech word"
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
def type_run(text, cfg=None, context="general"):
    """Types `text` from an empty field: runs of ASCII letters are tokens, every other character is a boundary
    (9.2). Returns the field and the reason of the last decided token."""
    cfg = cfg or Cfg()
    out, window, reason = "", [], None
    for token, boundary in re.findall(r"([A-Za-z]*)([^A-Za-z]*)", text):
        if token:
            C, reason = decide(token, cfg, "en" if run_is_english(window) else "neutral", context)
            window.append(lang_of_decision(C, reason))
            out += C
        out += boundary
    return out, reason
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
if __name__ == "__main__":
    bad = [(keys, type_run(keys), (want, why)) for keys, want, why in RUNS if type_run(keys) != (want, why)]
    for row in bad: print("mismatch:", row)
    print(f"{len(RUNS) - len(bad)}/{len(RUNS)} English-run examples agree")
    sys.exit(1 if bad else 0)
