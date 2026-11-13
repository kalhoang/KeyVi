# SPDX-License-Identifier: MPL-2.0
import sys; sys.path.insert(0,'.')
from compose import compose, Cfg, commit, display
from ortho import validity, VOWELS, strip
EN = set("""test this these there best max list been text user wifi usb case password traffic boss coffee as is was has its us car did theme does door her post says war two wow ask task zoom more year mother keyboard verbose startup data plans grows www less tomorrow the and you a i cost room tar class""".split())
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
