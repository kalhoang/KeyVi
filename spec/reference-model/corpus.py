# SPDX-License-Identifier: MPL-2.0
import sys, unicodedata; sys.path.insert(0,'.')
from ortho import all_syllables, tones_for, tone_target, apply_tone, TONE_MARKS, parse
from compose import compose, Cfg, display, commit
TEL_T = {1:'s',2:'f',3:'r',4:'x',5:'j'}
VNI_T = {1:'1',2:'2',3:'3',4:'4',5:'5'}
def oracle(o, r, tone, style):
    s = o + r
    # open ươ normalisation not needed: tier A has no open ươ
    if tone == 0: return s
    t = tone_target(s, style)
    return s[:t] + apply_tone(s[t], tone) + s[t+1:]
def keys_for_letter(c, im):
    # returns (base, modkey) ; modkey typed right after base in O1
    tel = {'ă':('a','w'),'â':('a','a'),'ê':('e','e'),'ô':('o','o'),'ơ':('o','w'),'ư':('u','w'),'đ':('d','d')}
    vni = {'ă':('a','8'),'â':('a','6'),'ê':('e','6'),'ô':('o','6'),'ơ':('o','7'),'ư':('u','7'),'đ':('d','9')}
    m = tel if im=='telex' else vni
    return m.get(c,(c,''))
def seqs(o, r, tone, im):
    s = o + r
    onset, run, coda, rest, i, j = parse(s)
    tk = (TEL_T if im=='telex' else VNI_T).get(tone,'')
    out = {}
    # O1 canonical: modifier right after letter; for ươ use explicit per-letter in VNI/telex 'uwow' style? use single w after o for pair
    o1=[]
    for idx,c in enumerate(s):
        b,m = keys_for_letter(c, im)
        o1.append(b)
        if m:
            # for ươ pair, emit modifier only after the o (pair rule)
            if c=='ư' and idx+1<len(s) and s[idx+1]=='ơ':
                continue
            o1.append(m)
    out['O1'] = ''.join(o1)+tk
    # O2 tone right after vowel group
    pre = ''.join(out['O1'][:0])
    # rebuild: letters up to j with mods, then tone, then coda
    def build(upto):
        res=[]
        for idx,c in enumerate(s[:upto]):
            b,m=keys_for_letter(c,im); res.append(b)
            if m and not (c=='ư' and idx+1<len(s) and s[idx+1]=='ơ'): res.append(m)
        return ''.join(res)
    out['O2'] = build(j)+tk+''.join(keys_for_letter(c,im)[0]+keys_for_letter(c,im)[1] for c in s[j:])
    # O3 all at end: bases, then stroke, modifiers, tone
    bases=''.join(keys_for_letter(c,im)[0] for c in s)
    mods=[]
    if s.startswith('đ'): mods.append('d' if im=='telex' else '9')
    seen_pair=False
    for idx,c in enumerate(s):
        if c in 'ăâêôơư':
            if c=='ư' and idx+1<len(s) and s[idx+1]=='ơ': continue
            mods.append(keys_for_letter(c,im)[1])
    out['O3'] = bases+''.join(mods)+tk
    # O4 tone right after first vowel of group
    if tone:
        out['O4'] = build(i+1)+tk+build(len(s))[len(build(i+1)):]
    return out
fails=[]; total=0
for o,r in sorted(all_syllables('A')):
    for tone in tones_for(r):
        for im in ('telex','vni'):
            for style in ('old','new'):
                exp = oracle(o,r,tone,style)
                for name,k in seqs(o,r,tone,im).items():
                    if im=='telex' and 'oo' in (o+r):
                        # the first 'oo' pair in key order is a circumflex request in Telex; literal oo needs the escape 'ooo'
                        idx=k.find('o'); 
                        # insert an extra 'o' after the first 'o' that is followed (possibly after a tone key) by another 'o'
                        import re
                        k=re.sub(r'o([sfrxj]?)o', lambda m: 'o'+m.group(1)+'oo', k, count=1)
                    cfg=Cfg(im,style)
                    st=compose(list(k),cfg); got=commit(st,cfg)
                    total+=1
                    if got!=exp: fails.append((name,im,style,k,exp,got))
print('total',total,'fails',len(fails))
from collections import Counter
print(Counter((f[0],f[1]) for f in fails))
for f in fails[:60]: print(f)
