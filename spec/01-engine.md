# 01. Engine: Vietnamese composition core

| Field | Value |
|---|---|
| Spec file | `01-engine.md` |
| Requirement prefix | `ENG-R` (requirements), `ENG-T` (tests), `REG` (regressions), `W` / `B` / `E` (worked examples) |
| Status | Draft v0.2, 2026-11-13 (adversarial review applied: contamination scan clean, linguistic fixes, cross-file alignment) |
| Owner | Pa Kal |
| Product names | `{{AppName}}` (display name), `{{app-slug}}` (ASCII slug). No name is chosen in this file. |
| Engine licence intent | Embeddable by any app, with file-level copyleft: MPL-2.0 (see ENG-R109). App licence is decided elsewhere. |

Keywords MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119. Anything marked **VERIFY:** is not confirmed and must be checked before it is relied on.

**Clean-room statement.** This file describes behaviour, contracts and constraints derived from public knowledge of Vietnamese orthography, the public definitions of Telex and VNI, Unicode, Apple documentation and user-reported problems with existing input methods. It contains no code, identifiers, table layouts or orderings from XKey, OpenKey, Unikey or any GPL project. Implementers MUST NOT consult those sources. All Swift signatures below are new designs.

---

## 0. Terms

| Term | Meaning |
|---|---|
| Key | One character delivered by the host after keyboard-layout mapping (`"a"`, `"A"`, `"6"`, `" "`, `"\n"`). The engine never sees key codes. |
| Token | The run of keys the engine is composing, from the first key after a boundary or reset up to the next boundary. One token is at most one Vietnamese syllable. |
| Raw keys | The exact characters typed for the token, case preserved, after Backspace edits (section 7.4). |
| Letters | The engine's internal letter sequence for the token: base letter, vowel modifier (breve, circumflex, horn), d-stroke, letter case. |
| Display | The text the engine believes is on screen for the token right now. |
| Transform key | A key that changes letters or tone instead of adding a letter: Telex `s f r x j z a e o w d` (and `[ ]` when enabled), VNI `0`-`9`. |
| Boundary | A key that ends the token (space, punctuation, Return...). See section 9. |
| Commit | What the engine does at a boundary: final normalisation and the restore decision (section 8). |
| Reset | An event telling the engine that its picture of the text before the cursor is no longer reliable. State is dropped and no text is edited. |
| Run | The tokens committed since the last reset in the same text field. |
| History | Committed tokens of the current run kept so that Backspace can re-open them (section 10). |
| Literal mode | Per-token state in which every further key is appended exactly as typed. |
| Tier A / Tier B / invalid | Standard Vietnamese / extended (names, loans, teencode) / neither. Section 3.12. |
| Viable | The letters typed so far can still grow into a Tier B syllable. Section 3.14. |
| Traditional / modern style | Tone placement conventions `hòa, khỏe, thủy` / `hoà, khoẻ, thuỷ`. Section 5.2. |

---

## 1. Scope for v1

### 1.1 What the engine does

- **ENG-R101** The engine MUST support two input methods: Telex and VNI (key maps in section 4).
  *Rationale: these two cover virtually all Mac users; other schemes add settings without users.*
- **ENG-R102** The engine MUST output Unicode text in Normalization Form C using only precomposed Vietnamese letters (for example U+1EC7 for `ệ`, U+0111 for `đ`). It MUST NOT emit combining marks.
  *Rationale: every Vietnamese letter has a single precomposed code point, which makes deletion counts exact (section 6.4).*
- **ENG-R103** Telex MUST offer one option, **standalone w** (`w` typed while the token has no vowel yet becomes the vowel `ư`, as in `w` -> `ư`, `thw` -> `thư`), default ON. When OFF, `w` is only a modifier key. This option replaces the separate "Simple Telex" input methods found in other products.
  *Rationale: most Telex users expect `w` = `ư`; the English words it used to damage (`wifi`, `with`, `world`) are now repaired by restore (section 8). One toggle is clearer than two near-identical methods.*
- **ENG-R104** Telex MUST offer one option, **bracket keys** (`[` = `ơ`, `]` = `ư`), default OFF.
  *Rationale: brackets collide with code, Markdown and emoticons; users reported `[[` / `]]` turning into `?` or `ư`.*
- **ENG-R105** The engine MUST support traditional and modern tone placement (section 5.2). Default: traditional. Open question Q2 for Pa.
- **ENG-R106** Automatic restore of non-Vietnamese words MUST be ON by default and MUST NOT require any download (section 8).
- **ENG-R107** Free-order entry (tone, modifier and `đ` keys typed after later letters, section 4.6) MUST always be on. There is no "free marking" setting.
  *Rationale: in the audited incumbent the most frequent support answer was "turn on free marking", which means the default was wrong. With the viability rule (sections 3.14 and 4.4) free order has no false positives on valid Vietnamese.*
- **ENG-R108** The engine MUST accept a **restore toggle** event that switches the current token between its Vietnamese form and the keys as typed (section 7.2). The host binds it to a hotkey (`03-product.md` D8: Escape by default, with a setting to turn it off or choose another key).
- **ENG-R109** The engine MUST be a standalone Swift package with no dependency on the app. Its licence is MPL-2.0 (decision of the product owner, 15/11/2026, `docs/decisions/0006-app-licence-and-pro-edition.md`): `LICENSE` is the verbatim MPL-2.0 text, `NOTICE` holds the copyright line, and no file is marked "Incompatible With Secondary Licenses".
  *Rationale: file-level copyleft keeps changes to the engine's own files open, while any app, closed source or on the App Store, can still embed the engine. Through the Secondary Licenses of MPL-2.0 section 3.3 it combines with GPL-2.0, LGPL-2.1, AGPL-3.0 and GPL-3.0 projects, this app included; Apache-2.0 would not combine with GPL-2.0. The first version said MIT; the change was decided before any release, so no MIT copy was ever distributed. Bundled word lists keep their own notices (section 8.2).*
- **ENG-R110** The engine MUST match and expand macros (text expansion) at commit, as specified in section 11. The macro table is user data supplied by the host; the engine ships with an empty table.
  *Rationale: every Vietnamese input method users compare against has macros; doing the match inside the engine keeps the edit exact and the trigger restorable.*

### 1.2 Non-goals for v1

- **ENG-R120** No legacy encodings: no TCVN3 (ABC), VNI-Windows, VIQR output, Windows-1258, and no decomposed (NFD) output.
  *Rationale: they were broken in the incumbent, are rarely needed on macOS today, and every one of them multiplies test surface. A host-side converter can be added later without touching the engine.*
- **ENG-R121** No "Quick Telex" shortcuts (`cc`, `gg`, `kk`, `nn`, `tt`, `pp`, `qq`, `uu` expanding to consonant clusters) and no quick start or end consonants. Not even as an option.
  *Rationale: they were on by default in the incumbent and mangled ordinary typing (`cc` became `ch`, `kkk` became `khk`, `nn` became `ng`, `tt` became `th`).*
- **ENG-R122** No dictionary spell checking and no "suggest a correction" feature. Restore (section 8) is the only correction the engine makes. *(Amended 18/11/2026: 1.1.0 adds the typo correction of section 11A under PRD-R4A, which replaces one clearly mistyped word with the only word it can be; there is still no suggestion list and no spell checking of Vietnamese.)*
- **ENG-R123** No automatic capitalisation of sentence starts in the engine (host feature, later version).
- **ENG-R124** No word prediction, autocomplete, translation or any feature that sends text anywhere.
- **ENG-R125** Withdrawn on review: macros are in v1 (ENG-R110, section 11). The number is kept so that references stay stable.
- **ENG-R126** No VIQR input, no other Vietnamese schemes, no Nôm.
- **ENG-R127** No multi-syllable segmentation: text typed without spaces is composed one syllable at a time and anything that does not fit one syllable goes literal.
- **ENG-R128** The engine performs no file, network or logging I/O of any kind.

---

## 2. Architecture in one paragraph

The host (event tap or input-method controller, specified elsewhere) converts each physical key into a character using the active keyboard layout and sends it to the engine together with control events (Backspace, restore toggle, resets). The engine is a pure function `reduce(state, event) -> (state, output)`. The output says whether the host lets the original key through or replaces text (delete N characters before the cursor, insert a string), and carries the current composing text for marked-text hosts, a reason code when a token is committed, and an optional learning signal. The engine has no global state, no I/O and no knowledge of which app is in front except a small context hint chosen by the host (section 8.6).

---

## 3. Syllable model

### 3.1 Structure

A Vietnamese syllable is `[onset] [medial] nucleus [coda] + tone`. In spelling, a written syllable is: onset letters, then a **vowel group** (medial glide, nucleus and any semivowel ending, all written with vowel letters), then an optional **consonant coda**, plus one tone mark on one vowel letter.

### 3.2 Letters, modifiers and tones

- Vowel letters (12): `a ă â e ê i o ô ơ u ư y`.
- Consonant letters used by Tier A: `b c d đ g h k l m n p q r s t v x`. Tier B adds `z` as an onset and `k` as a coda (section 3.12).
- Vowel modifiers: breve (`ă`), circumflex (`â ê ô`), horn (`ơ ư`). Stroke: `đ`.
- Six tones: ngang (no mark), sắc (acute), huyền (grave), hỏi (hook above), ngã (tilde), nặng (dot below). In this file tones are numbered 0 to 5 in that order. Output uses precomposed letters only (ENG-R102).
- **ENG-R301** The engine MUST contain a generated table of all 146 Vietnamese letters it can emit (12 vowels x 6 tones x 2 cases, plus `đ` and `Đ`; the six untoned `a e i o u y` are plain ASCII), built from Unicode character data and ordered by code point. No other source may be used for this table.

### 3.3 Onsets

| Onset | Tier | Constraint |
|---|---|---|
| (none) | A | See 3.10 for vowels that may start a syllable. |
| `b` `m` `p` `ph` `v` | A | Labials. No medial glide after them in Tier A (Tier B allows loans such as `buýt`, `phuy`, `voan`). `p` is accepted (loans and rare native words: `pin`, `pía`). |
| `c` | A | Only before vowels that are not `e ê i y iê ia`. Never with a medial glide (that sound is written `qu`). |
| `k` | A | Only before `e ê i y` and `iê/ia`. Tier B: before any vowel (`Kon`, `Kạn`, `Krông`). |
| `q` | A | Only as `qu`; the `u` is the medial glide and is never tone-bearing. Rhymes after `qu`: section 3.8. |
| `g` | A | Not before `e ê iê ia y`. Before an `i` rhyme with no further vowel letter (`gì`, `gìn`, `gỉ`) the spelling `gi` stands for the `gi` onset plus nucleus `i`; this is valid. |
| `gh` | A | Only before `e ê i` and `iê/ia`. |
| `gi` | A | Recognised as the onset when the letter after `gi` is a vowel letter. Absorbs the `i` of `iê`: `gi + iêc` and `gi + iêng` are written `giêc`, `giêng` (`giếc`, `giếng`). Rhymes after `gi`: section 3.9. |
| `ng` | A | Not before `e ê i y iê ia`. |
| `ngh` | A | Only before `e ê i` and `iê/ia`. |
| `ch` `d` `đ` `h` `kh` `l` `n` `nh` `r` `s` `t` `th` `tr` `x` | A | No special constraint beyond 3.10. |
| `bl` `br` `dr` `đr` `gl` `gr` `kl` `kr` `pl` `pr` | B | Clusters found in ethnic-minority place names (`Krông`, `Đắk Glong`, `M'Đrắk`, `Ia Grai`, `Kon Plông`, `Chư Prông`). |
| `z` | B | Teencode (`zá`, `zui`, `zậy`). |
| `dz` | B | Colloquial (mostly Southern) spelling of the `d`/`v` sound: `dzô`, `dzậy`, `dzui`, `dzữ`, `dzìa`. Follows the same constraints as `d`. In Telex the `z` of `dz` arrives before any vowel and after an unstroked `d`, so ENG-R411 finds nothing to remove and makes it a letter, never tone removal (after `đ` it removes the stroke: `ddz` -> `d`). Required by the product owner (P0-2 in 03-product.md). |

`f`, `j` and `w` are not onsets in any tier. In Telex `f` and `j` are tone keys and `w` is a vowel modifier; a token that starts with them is never Vietnamese, so it goes literal at once (`facebook`, `java` are never touched). Decision (Pa, 13/11/2026): the slang onsets supported are `z` and `dz`; `f`, `j` and `w` stay out because they would make common English words (`for`, `fix`, `jar`, `was`) compose.

- **ENG-R316** Whether a token is Vietnamese is decided only by the rules of this section (Tier A / Tier B), never by a word list. The attested-syllable data of section 8 may only break a tie when the raw keys are also an English word; it MUST NOT cause a valid syllable whose raw keys are not English to be restored. A valid syllable that no dictionary contains (`hẹo`, `dzậy`, `quởn`) therefore composes and is kept at commit exactly like a dictionary word, and the result is the same whichever boundary key ends it (REG-28, REG-29).

### 3.4 Medial glide

- Written `o` before `a ă e` (`hoa`, `hoặc`, `khoẻ`).
- Written `u` before `â ê ơ y yê` (`xuân`, `huệ`, `huơ`, `tuy`, `khuyên`) and always after `q`.
- Forbidden after `c k gh ngh gi` and, in Tier A, after labials (3.3).

### 3.5 Nuclei and vowel groups

- Monophthongs: `a ă â e ê i/y o ô ơ u ư`, plus the long `oo` of loans (`boong`, `soóc`).
- Diphthongs: `iê` (written `ia` when open, `iê` before a coda, `yê` with no onset or after the medial `u`, `ya` only in `uya`), `uô` (written `ua` open, `uô` closed), `ươ` (written `ưa` open, `ươ` closed; `uơ` in `huơ`, `thuở`).
- Three-letter vowel groups, in alphabetical order: `iêu oai oay oeo uây uôi uya uyu ươi ươu yêu`, plus `uyê` (always closed) and the Tier B `oao`.

### 3.6 Codas

- Consonant codas: `c ch m n ng nh p t`. Tier B adds `k` as a spelling variant of `c` (`Đắk`, `Lắk`, `Búk`).
- Semivowel endings `i y o u` are part of the vowel group in spelling (`ai`, `ay`, `ao`, `au`).
- Which codas follow which vowels is fully determined by the rhyme inventory below; the engine MUST NOT encode separate coda rules that disagree with it.

### 3.7 Rhyme inventory, Tier A (156 rhymes)

Rhymes are written as they appear after an ordinary consonant onset. Grouped by nucleus; one example word each.

| Nucleus group | Rhymes (example) | Count |
|---|---|---|
| a | `a` ba, `ac` các, `ach` sách, `ai` hai, `am` cam, `an` bàn, `ang` sang, `anh` anh, `ao` cao, `ap` đáp, `at` hát, `au` sau, `ay` tay | 13 |
| medial o + a | `oa` hoa, `oac` khoác, `oach` hoạch, `oai` ngoài, `oam` ngoạm, `oan` toàn, `oang` hoàng, `oanh` doanh, `oat` thoát, `oay` xoáy | 10 |
| ă | `ăc` mặc, `ăm` năm, `ăn` ăn, `ăng` răng, `ăp` gặp, `ăt` mắt | 6 |
| medial o + ă | `oăc` ngoặc, `oăm` hoắm, `oăn` xoăn, `oăng` hoẵng, `oăt` thoắt | 5 |
| â | `âc` bậc, `âm` âm, `ân` cân, `âng` tầng, `âp` lập, `ât` mất, `âu` đâu, `ây` đây | 8 |
| medial u + â | `uân` xuân, `uâng` khuâng, `uât` thuật, `uây` khuấy | 4 |
| e | `e` xe, `ec` séc, `em` em, `en` đen, `eng` xẻng, `eo` mèo, `ep` đẹp, `et` hét | 8 |
| medial o + e | `oe` khoẻ, `oen` hoen, `oeo` ngoẹo, `oet` khoét | 4 |
| ê | `ê` về, `êch` ếch, `êm` đêm, `ên` tên, `ênh` bệnh, `êp` bếp, `êt` hết, `êu` kêu | 8 |
| medial u + ê | `uê` huệ, `uêch` khuếch, `uênh` huênh | 3 |
| i | `i` đi, `ich` thích, `im` tim, `in` tin, `inh` xinh, `ip` kịp, `it` ít, `iu` dịu | 8 |
| y (open) | `y` ý, kỹ | 1 |
| medial u + y | `uy` tuy, `uych` huých, `uyn` tuyn, `uynh` huynh, `uyp` tuýp, `uyt` huýt, `uyu` khuỷu | 7 |
| iê / ia | `ia` mía, `iêc` việc, `iêm` kiếm, `iên` tiên, `iêng` tiếng, `iêp` tiếp, `iêt` biết, `iêu` hiểu | 8 |
| yê (no onset only) | `yêm` yếm, `yên` yên, `yêng` yểng, `yêt` yết, `yêu` yêu | 5 |
| medial u + iê | `uya` khuya, `uyên` khuyên, `uyêt` tuyệt | 3 |
| o | `o` to, `oc` học, `oi` đói, `om` gom, `on` con, `ong` mong, `op` họp, `ot` ngọt | 8 |
| oo (loans) | `ooc` soóc, `oong` boong | 2 |
| ô | `ô` cô, `ôc` ốc, `ôi` tôi, `ôm` ôm, `ôn` hôn, `ông` không, `ôp` hộp, `ôt` một | 8 |
| ơ | `ơ` cơ, `ơi` với, `ơm` cơm, `ơn` hơn, `ơp` lớp, `ơt` ớt | 6 |
| medial u + ơ | `uơ` huơ, thuở (only after `h`, `th` in Tier A) | 1 |
| u | `u` thu, `uc` lúc, `ui` vui, `um` cúm, `un` bún, `ung` chung, `up` húp, `ut` phút | 8 |
| uô / ua | `ua` của, `uôc` cuộc, `uôi` tuổi, `uôm` buồm, `uôn` muốn, `uông` uống, `uôt` suốt | 7 |
| ư | `ư` thư, `ưc` đức, `ưi` gửi, `ưng` những, `ưt` đứt, `ưu` cứu | 6 |
| ươ / ưa | `ưa` mưa, `ươc` được, `ươi` người, `ươm` bướm, `ươn` vườn, `ương` đường, `ươp` cướp, `ươt` vượt, `ươu` rượu | 9 |
| **Total** | | **156** |

- **ENG-R302** The engine's Tier A rhyme set MUST be exactly this table plus the `qu` and `gi` rules of 3.8 and 3.9. Adding or removing a rhyme requires a spec change and a corpus update.
- **ENG-R303** `ch`/`nh` codas appear only after `a`, `ê`, `i` and the medial forms `oa`, `uê`, `uy`; this is a property of the table, listed here so that reviewers can check it.

### 3.8 Rhymes after `qu` (41 rhymes)

After `qu` the medial glide is already present, so the rhyme is written without it.

`a` quà, `ac` quác, `ach` quách, `ai` quai, `an` quan, `ang` quang, `anh` quanh, `ao` quào, `at` quát, `au` quạu, `ay` quay, `ăc` quắc, `ăm` quắm, `ăn` quăn, `ăng` quăng, `ăp` quặp, `ăt` quắt, `ân` quân, `âng` quầng, `ât` quất, `ây` quây, `e` que, `en` quen, `eo` quẹo, `et` quét, `ê` quê, `êch` quệch, `ên` quên, `ênh` quềnh, `êt` quết, `êu` quều, `i` qui, `it` quít, `y` quý, `ych` quých, `ynh` quỳnh, `yt` quýt, `yên` quyên, `yêt` quyết, `ơ` quơ, `ôc` quốc.

Tier B adds `o` (quọ) and `ơn` (quởn).

- **ENG-R304** `qui`/`quy`, `quít`/`quýt` are both valid. The engine MUST keep the letter the user typed.

### 3.9 Rhymes after `gi`, and `g` + `i`

- **ENG-R305** When `g i` is followed by another vowel letter, the onset is `gi` and the rhyme is the rest. Allowed rhymes after `gi`: every Tier A rhyme that does not start with `i` or `y` and does not start with a medial glide, plus `êc` and `êng` (from `gi + iêc` and `gi + iêng`: `giếc` as in `cá giếc`, `giếng`, `giêng`). Examples: `già`, `giữ`, `giúp`, `giỏi`, `giấy`, `giết`, `giũa`, `giuộc`, `giường`. Tier B adds medial rhymes (`gioăng`).
  *Review note: `êc` was missing from the first draft; without it `giếc` would have been restored to `gieecs`.*
- **ENG-R306** When `g i` is not followed by a vowel letter, the parse is onset `g` plus an `i` rhyme (`gì`, `gìn`, `gỉ`), and this is valid in Tier A.
- **ENG-R307** The `gi` decision is made on the current letters every time (section 6.1). Typing `g i s u p` shows `gí` after the third key and `giú` after the fourth, because the arrival of `u` turns `i` into part of the onset (REG-11).

### 3.10 Spelling constraints (Tier A)

- **ENG-R310** `k`, `gh`, `ngh` only before `e ê i y iê ia`; `c`, `g`, `ng` never before them, except the `g` + `i` case of ENG-R306.
- **ENG-R311** `q` only as `qu`, followed by a rhyme from 3.8.
- **ENG-R312** Medial rhymes (`oa… oă… oe… uâ… uê… uy… uya uyê… uơ`) are invalid after `c k gh ngh gi`, and after `b m p ph v` in Tier A.
- **ENG-R313** `yê…` rhymes only with no onset. With no onset, `iê…` is invalid (`yêu`, never `iêu`); `ia` with no onset is valid (`ỉa`).
- **ENG-R314** Open `y` (the rhyme `y`) is Tier A only with no onset or after `h k l m s t th v` (`ý`, `hy`, `kỹ`, `lý`, `mỹ`, `sỹ`, `tỷ`, `Thy`, `Vy`); after other onsets it is Tier B. Open `i` is valid after every onset that allows `i`. Article 9 of Decision 1989/QĐ-BGDĐT (2018) prescribes `i` after an onset in textbooks (`kĩ`, `lí`, `mĩ`) but keeps `y` in proper names (`Vy`, `Vỹ`, `Thy Ngọc`); the engine accepts both spellings and never rewrites one into the other.
- **ENG-R315** `uơ` is Tier A only after `h` and `th`; elsewhere Tier B.
- **ENG-R317** `ươ` with no coda and no ending (open) is never valid in the committed text; see 5.5. *(Numbered ENG-R316 in the first version, which duplicated the ID of 3.3; renumbered by the product owner's decision of 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md.)*

### 3.11 Tone constraints

- **ENG-R320** Rhymes ending in `c`, `ch`, `p`, `t` accept only sắc and nặng. All other rhymes accept all six tones.
- **ENG-R321** In Tier B the `k` coda accepts all six tones (`Đăk Mil` is written with and without sắc in practice).

### 3.12 Validity tiers and the policy for names, loans and slang

| Tier | Definition | Purpose |
|---|---|---|
| A (standard) | Onset of 3.3 marked A, rhyme from 3.7 / 3.8 / 3.9, all constraints of 3.10 and 3.11. | What a Vietnamese dictionary accepts. |
| B (extended) | Tier A, plus: onsets marked B; `k` before any vowel; `k` coda as a variant of `c` with any tone; medial glide after labials and after `gi`; open `y` after any onset; `uơ` after any onset; extra rhymes `oao oap oăp oem oeng oec oep uên uêt uêu ưm ưn ưp`; `qu` + `o`, `qu` + `ơn`. | Ethnic-minority place names (`Krông Pắk`, `Đắk Lắk`, `Kon Plông`), established loans (`buýt`, `phuy`, `voan`), interjections (`ừm`) and teencode or colloquial spellings (`zá`, `hok`, `dzô`, `dzậy`). |
| Invalid | Anything else. | Restored at commit (section 8). |

Readings of the Tier B row confirmed by the product owner (13/11/2026, docs/decisions/0100-engine-syllable-counts.md): the `k` coda variant does not apply after `qu` or `gi`; the medial rhymes allowed after `gi` are only those that start with the medial `o` (`gioăng`), because `u` + vowel after `gi` is already the nucleus `u` (`giũa`, `giuộc`); and no medial glide follows `kl` or `kr` (3.4 forbids it after `k`).

- **ENG-R330** Composition (section 4) MUST use Tier B to decide what can still be typed, so that names and loans compose normally.
- **ENG-R331** At commit, a Tier B word that is not Tier A is kept unless its raw keys are an English word (section 8, rule L6). Names such as `Krông` (raw `kroong`), `Đắk` (raw `ddawsk`) and `Pắc` are therefore never restored.
- **ENG-R332** Proper nouns are not detected by capitalisation. Capitalised words follow the same rules as lowercase words.
  *Rationale: sentence starts are capitalised too; capital letters carry no reliable signal.*
- **ENG-R333** Place names written with an apostrophe (`M'Đrắk`, `Đắk R'lấp`, `Cư M'gar`) are handled as two tokens because the apostrophe is a boundary (section 9); each part composes on its own.
- **ENG-R334** Words outside Tier B that a user still wants (rare slang, brand spellings) are covered by the user "keep as typed" and "keep Vietnamese" lists (section 8.7), never by widening the tiers ad hoc.

### 3.13 Parsing a letter string (normative)

Input: a lowercase letter string with modifiers (tone marks removed). Output: onset, vowel group, coda, remainder.

1. Onset: if the string starts with `qu`, onset is `qu`. Else if it starts with `gi` and the third letter is a vowel letter, onset is `gi`. Else the longest multi-letter onset that matches, taken from the alphabetical set `bl br ch dr dz đr gh gl gr kh kl kr ng ngh nh ph pl pr th tr` (longest match, so `ngh` wins over `ng`). Else, if the first letter is a consonant, that letter. Else no onset.
2. Vowel group: the maximal run of vowel letters after the onset.
3. Coda: the maximal run of consonant letters after the vowel group.
4. Remainder: anything after the coda. A non-empty remainder or an empty vowel group makes the string invalid.
5. Validity: look up (onset, vowel group + coda) in Tier A, then Tier B, then check the tone against 3.11.

- **ENG-R340** The parse MUST be a pure function of the letters. It MUST NOT depend on keys, history or configuration.

### 3.14 Viability (normative)

- **ENG-R345** The letters of a token are **viable** if, after the display normalisation of 5.5, they are a prefix of at least one Tier B syllable (tone ignored), where an unmodified vowel letter matches the same letter with any modifier and `d` matches `d` or `đ`. A modified vowel letter matches only itself.
- **ENG-R346** Viability MUST be computed from a structure generated from the tier tables (a trie, sorted prefix set or automaton). It MUST NOT be hand-written.

### 3.15 Reference counts

The generator of the implementation, built from the tables above, prints: 156 Tier A rhymes, 41 `qu` rhymes, **3,367** Tier A onset-rhyme pairs, **15,406** Tier A toned syllables, and **6,208** Tier B onset-rhyme pairs including Tier A (**6,387** with the `dz` onset of 3.3, which adds the 179 Tier B pairs of `d`).

*History: the first version of this section quoted a throwaway reference model (spec/reference-model/, not shipped): 3,368 / 15,412 / 6,209 after the review additions of `gi + êc` (ENG-R305) and `th + y` (ENG-R314), 3,366 / 15,404 / 6,208 before them. The model counts the spelling `giu` twice (as `g` + `iu` and as `gi` + `u`), but the parse of 3.13 reads it only as `gi` + `u`, so each of its counts was one pair (six toned syllables) too high. The product owner adopted the implementation's numbers on 13/11/2026 (docs/decisions/0005-pa-decisions-2026-11-13.md, analysis in docs/decisions/0100-engine-syllable-counts.md).*

- **ENG-R350** The implementation's generator MUST print its own counts in CI. Any difference from these numbers MUST be explained in the pull request that introduces it (either the tables or the implementation is wrong).

---

## 4. Key maps

### 4.1 Telex

| Key | Role | Effect | Example |
|---|---|---|---|
| `s` | tone | sắc | `as` -> `á` |
| `f` | tone | huyền | `af` -> `à` |
| `r` | tone | hỏi | `ar` -> `ả` |
| `x` | tone | ngã | `ax` -> `ã` |
| `j` | tone | nặng | `aj` -> `ạ` |
| `z` | tone removal | removes one layer per press: the tone, then every vowel mark and the stroke at once; a letter if there is neither (ENG-R411) | `asz` -> `a`, `aaz` -> `a`, `daauszz` -> `dau`, `za` -> `za` |
| `a` `e` `o` | circumflex | on the same letter in the vowel group | `aa` -> `â`, `ee` -> `ê`, `oo` -> `ô`, `cuwowio` -> `cuôi` |
| `w` | horn / breve | `a` -> `ă`, `o` -> `ơ`, `u` -> `ư`, `uo` -> `ươ`, `ua` -> `ưa` (not after `q`), `qua` -> `quă`, `oa` -> `oă`, `uu` -> `ưu`, `ui` -> `ưi`; alone -> `ư` (option) | `aw` -> `ă`, `tuowng` -> `tương`, `w` -> `ư` |
| `d` | stroke | `d` that starts the token -> `đ` | `dd` -> `đ`, `dangd` -> `đang` |
| `[` `]` | letters (option, default off) | `ơ`, `ư` | `[` -> `ơ` |
| other letters | letter | | |

All roles apply to uppercase keys too. The case of a transform key never matters; the case of each output letter comes from the key that produced that letter (section 9.1), except the escaped letter of a standalone `w` doubling, which takes the capital of the `ư` it removed (ENG-R903: `Ww` -> `W`).

### 4.2 VNI

| Key | Role | Effect |
|---|---|---|
| `1` `2` `3` `4` `5` | tone | sắc, huyền, hỏi, ngã, nặng |
| `0` | tone removal | removes one layer per press: the tone, then every vowel mark and the stroke at once; literal `0` if there is neither (ENG-R411) |
| `6` | circumflex | on `a`, `e` or `o` in the vowel group (rightmost eligible first) |
| `7` | horn | on `o` or `u`; `uo` -> `ươ`, `ua` -> `ưa`, `uu` -> `ưu`, `ui` -> `ưi` |
| `8` | breve | on `a` (`oa` -> `oă`, `qua` -> `quă`) |
| `9` | stroke | `d` that starts the token -> `đ` |
| letters | letter | |

- **ENG-R401** Digits typed on the numeric keypad (host sets `fromKeypad`) MUST NOT act as VNI keys; they are boundaries.
- **ENG-R402** Shifted digits produce symbols (`@`, `(`, `!`...) and are boundaries; the engine sees the symbol, never the digit (REG-14).
- **ENG-R403** In VNI, Telex transform letters are plain letters and in Telex, digits are boundaries. The two methods MUST never mix: no VNI output ever contains a transform that only Telex defines, and the restore of a VNI token reproduces the digits typed (REG-05).

### 4.3 Order of interpretation for each key (normative)

For each key while composing a token:

1. If the token is in literal mode, append the key verbatim and stop.
2. If the key has a transform role whose kind has not been escaped in this token (4.7), try the roles in this order and stop at the first that applies: tone or tone removal, circumflex, horn or breve, stroke, standalone `w`, bracket letters.
3. Otherwise treat the key as a letter: append it. If the letters are no longer viable (3.14), enter literal mode (4.5).
4. A VNI digit that does not apply is appended as a literal character and the token enters literal mode.

### 4.4 When a transform applies (normative)

- **ENG-R410 Tone.** Applies when the parse of the current letters has a non-empty vowel group (the `u` of `qu` and the `i` of a `gi` onset do not count). If the current tone equals the key's tone, the key escapes (4.7). Otherwise it replaces the current tone. Tone keys never fail because of the coda; an invalid tone/coda pair is judged at commit.
- **ENG-R411 Tone removal.** Removes one layer per press. If the token has a tone, the key removes it. Otherwise, if a letter carries a vowel mark (circumflex, horn or breve) or the token has `đ`, the key removes all of them at once (`đ` becomes `d`; the `ư` of a standalone `w` becomes `u`, `wz` -> `u`). Otherwise the key is a letter (Telex `z`) or literal (VNI `0`). So `daausz` -> `dâu`, `daauszz` -> `dau`, `daauszzz` -> `dauz`, `dduwowngfzz` -> `duong`, `aaz` -> `a`; VNI `a610` -> `â`, `a6100` -> `a`, `a61000` -> `a0`. A key with nothing to remove behaves as before: this is the only behaviour for `qu` with no vowel, `quz` -> `quz`, `qu0` -> `qu0`, never a crash (REG-01), and for a `z` before any vowel (`za`, `dz`; REG-25). After a removal every key keeps its role, as after a tone removal (`aszs` -> `á`): a tone key sets a tone, a modifier or stroke key marks again and a second press of it escapes (`aaza` -> `â`, `aazaa` -> `aa`, `daauszza` -> `dâu`, `ddzd` -> `đ`), and a further tone-removal key starts again from the top layer (`aazaz` -> `a`). Removing marks never makes the letters non-viable (the wildcard of ENG-R345). At commit a token whose last key is this key, and removed the tone or the marks, is decided by rule L4a (8.1): the user saw what the removal left and committed it, so the display is kept unless the raw keys are English, as an escape keeps its form (L4), whether or not the display is a syllable: `daauszz` + space keeps `dau`, `dduwowngfzz` + space keeps `duong`, `vieejtz` keeps `viêt` (a stop coda without sắc or nặng, 3.11) and `vieejtzz` keeps `viet`, VNI `vie65t0` keeps `viêt`; an English word that ends with such a removal is restored (`quartz`, `QUARTZ`). The earlier rules still decide first (the user's toggle and lists, L3, an escape in the same token: `aazaa` is decided by L4), and a token whose last key is a letter, a further removal key with nothing to remove included (`daauszzz` shows `dauz`), is decided by the rules after L4a. *(Amended by the product owner on 15/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, REG-34: the first version removed only the tone, so `daauszz` gave `dâuz` where `dau` was expected. Amended again by the product owner on 18/11/2026, Q9, REG-39: until then the commit decided such a token by 8.1 like any other, so `dduwowngfzz` + space restored `dduwowngfzz` because `duong` is not a syllable (L5), as it did for `vieejtz`. The condition on the last key, which keeps every example of the decision, follows L4, where an escape that ends the token is deliberate (ENG-R804 (d)); it was set when the rule was applied, after a sweep of `/usr/share/dict/words`: read anywhere in the token, the rule committed 193 English words and names typed through as text that is no syllable, `Amazon` as `Amon` (the `z` removes the circumflex that the second `a` gave the first), `Arizona` as `Aiona`.)* Known costs: a word outside the English lexicon that ends with a removal keeps what it shows, `bortz`, `hertz`, `wootz` commit `bot`, `het`, `uot` (3 words of `/usr/share/dict/words`; 9 more end with a syllable that L7 kept before, `hafiz` gives `hai`); the escape by doubling gives the word (`herrtz` gives `hertz`, 4.7), and so does the keep-as-typed list (L2).
- **ENG-R412 Circumflex.** Target: a letter in the vowel group with the key's base letter (Telex) or with base `a`, `e` or `o`, rightmost first (VNI `6`). If the target already has a circumflex, the key escapes. Otherwise the target gets a circumflex, replacing any horn or breve on it; if the target is the `o` of a `u o` pair, the horn is also removed from the `u` (`ươ` + `o` -> `uô`). The transform applies only if the result is viable; otherwise the next target is tried, then the key falls through to step 3.
- **ENG-R413 Horn and breve (Telex `w`).** Candidate target sets, in order: (a) a `u o` pair inside the vowel group (both letters get a horn), then (b) single letters of the vowel group from right to left: `a` gets a breve, `o` or `u` gets a horn. A set whose letters already carry exactly that modifier is skipped. The first set whose result is viable is applied. If none applies and the vowel group already has a horn or breve, the key escapes: every horn and breve in the vowel group is removed, an `ư` that was created by a standalone `w` is removed (a tone shown on it then has no letter, ENG-R432), and the key is appended as a letter. If none applies, the vowel group is empty and standalone `w` is on, `ư` is appended if viable. Otherwise the key falls through to step 3.
- **ENG-R414** VNI `7` follows ENG-R413 restricted to `o` and `u` with no standalone case. VNI `8` follows it restricted to `a`.
- **ENG-R415 Stroke.** Applies when the first letter of the token is `d`. An unstroked `d` becomes `đ` if viable; a stroked one escapes. Otherwise Telex `d` is a letter and VNI `9` is literal.
- **ENG-R416** A transform that would make the letters non-viable MUST NOT be applied. The key then becomes a letter or literal according to 4.3. Consequences: `chưa` + `a` -> `chưaa` (no `ưâ`), `cua` + `a` -> `cuaa` (no `c` + `uâ`), `khoa` + `a` -> `khoaa`, `q` + `w` -> `qw` (no `qư`) (REG-13, REG-20).

### 4.5 Literal mode

- **ENG-R420** When a letter makes the token non-viable, the token enters literal mode: the display at that moment is frozen and every later key of the token is appended exactly as typed, with no further transform.
  *Rationale: this stops double marking inside English words (`password` used to receive two marks) and keeps names like `mother`, `startup`, `keyboard` untouched from the first impossible letter (REG-19, REG-03).*
- **ENG-R421** Literal mode ends only at the end of the token, or when Backspace removes the key that caused it (the token is then recomputed, section 7.4).

### 4.6 Free-order entry

- **ENG-R430** Tone, modifier and stroke keys MAY be typed anywhere after the letters they act on, including after the coda: `caanf`, `caafn` -> `cần`; `hopwj`, `howjp` -> `hợp`; `dangd` -> `đang`; `chwa` -> `chưa`; `wngs`, `wsng` -> `ứng`; `mootj`, `moojt` -> `một`; `phucws` -> `phức`; VNI `vie6t5`, `vie65t` -> `việt`, `duoc795` -> `được` (REG-09).
- **ENG-R431** A circumflex key typed after the coda applies to the matching vowel (`cana` -> `cân`) because a vowel letter after a coda is never viable as a letter.
- **ENG-R432** A tone key typed before any vowel is a letter (`tsa` goes literal at `s`). A tone key whose vowel an escape removes later (a Telex `w` escape removing the `ư` of a standalone `w`, ENG-R413, or a bracket key removing its own letter, 4.8) shows on the next vowel of the token if one follows (`wsaw` shows `áw`: the escape removed the `ư`, so the sắc lands on the `a`); with no vowel after it, it shows on no letter for the rest of the token, which is literal from the escape key on (ENG-R442): `WSw` shows `w`. It is not a letter either: Backspace on the escape letter keeps it on the vowel that follows, or removes it with the escape, instead of bringing it back as a letter (ENG-R711: `wsaw` + Backspace -> `á`, `WSw` + Backspace leaves an empty token).

### 4.7 Escape by doubling

- **ENG-R440** Typing a transform key whose effect is already present removes the effect and appends the key itself as a letter (Telex) or literal character (VNI): `ass` -> `as`, `aaa` -> `aa`, `aww` -> `aw`, `ddd` -> `dd`, `ww` -> `w`, `nhaamff` -> `nhâmf`, VNI `a11` -> `a1`, `d99` -> `d9`. The escaped letter has the case of the escaping key, except after the `ư` of a standalone `w`, whose place it takes: `Ww` -> `W`, as `WW` and `wW` (ENG-R903, REG-41).
- **ENG-R441** Escape is sticky per kind for the rest of the token, or until Backspace deletes the escape letter (ENG-R711). Kinds: tone, circumflex, Telex `w`, VNI horn, VNI breve, stroke. After an escape, keys of that kind are letters (Telex) or literal (VNI). Example: `boooong` -> `booong`, while `booong` -> `boong`; `boss` + Backspace, `s` -> `bó`.
- **ENG-R442** The escaped letter is an ordinary letter for viability; if it makes the token non-viable, literal mode starts (`ass` -> `as`, then literal). The escaped letter that starts literal mode is shown in the case ENG-R903 gives it (`Wwade` shows `Wade`); every later key of the token is appended exactly as typed (ENG-R420).

### 4.8 What the options change

| Option | Default | Effect |
|---|---|---|
| Telex standalone `w` | on | Off: `w` never creates `ư` by itself; `tw` -> `tw`, `tuw` -> `tư` still works. |
| Telex bracket keys | off | On: `[` -> `ơ`, `]` -> `ư` as letters; doubling escapes (`[[` -> `[`). Off: brackets are boundaries. |
| Tone style | traditional | Section 5.2. |
| Auto restore | on | Off: commit never restores; everything else is unchanged. |

- **ENG-R450** There MUST be no other engine option in v1. `EngineConfiguration.lookaheadRevision` and `EngineConfiguration.lineStartRevision` (ENG-R829) are not composition options: like `appContext` (8.6) they are switches the host sets per app, here for the context rules of words that are both English and Vietnamese and for RV5 of the code context (ENG-R828, ENG-R850).

---

## 5. Tone placement

### 5.1 Rules (normative, apply in order)

Let the vowel group be the vowel letters after the onset (the `u` of `qu` and the `i` of a `gi` onset are not part of it).

1. **Modified letter.** If the vowel group contains `ă â ê ô ơ ư`, the tone goes on the last such letter. (`ươ` -> on `ơ`; `ưa`, `ưu`, `ưi` -> on `ư`; `uô`, `iê`, `yê`, `uyê`, `uâ`, `uê`, `oă`, `uơ` -> on the modified letter.)
2. **Consonant coda.** Else, if there is a consonant coda, the tone goes on the last letter of the vowel group (`toán`, `hoàn`, `huýt`, `huỳnh`, `soóc`, `tuýp`).
3. **Open or semivowel ending.** Else:
   - one vowel letter: on it;
   - two letters: for `oa`, `oe`, `uy`, on the first letter in traditional style and on the second in modern style; for every other pair (`ai ao au ay eo iu oi ui ia ua` and so on), on the first;
   - three letters: on the middle letter (`oai` -> `hoài`, `oay` -> `xoáy`, `oeo` -> `ngoẹo`, `uyu` -> `khuỷu`, `uya` -> `khuya` with tone on `y`);
   - four or more letters (never valid): on the second letter, so that the result is still deterministic.

- **ENG-R501** These rules MUST be applied to the current letters on every key (section 6.1); tone position is never stored.
- **ENG-R502** `qu` and `gi` onsets make placement identical in both styles: `quý`, `quả`, `quở`, `già`, `giữa`, `giũa`, `giếng`.

### 5.2 Traditional and modern style

| Vowel group (no coda) | Traditional (default) | Modern |
|---|---|---|
| `oa` | `hòa`, `óa` | `hoà`, `oá` |
| `oe` | `khỏe`, `lòe` | `khoẻ`, `loè` |
| `uy` | `thủy`, `ủy` | `thuỷ`, `uỷ` |

These three open pairs are the only difference. With a coda (`hoàn`, `khoét`, `huýt`) or with three letters (`hoài`, `ngoẹo`), both styles agree.

- **ENG-R510** Default MUST be traditional.
  *Rationale: it matches the bulk of existing digital Vietnamese text and the habit of adult users. Decision 1989/QĐ-BGDĐT (25 May 2018), Article 8.1, uses modern examples (`hoà nhạc`, `quý hoá`, `thuỷ thủ`, `mạnh khoẻ`) and its Article 1 limits its scope to curricula and textbooks, so students taught since 2018 may prefer modern while press, law and most existing text stay traditional (the Fisheries Law of 2017 is still titled `Luật Thủy sản`). Pa decides the final default (Q2). Verified against the published text of the decision on 13 November 2026.*
- **ENG-R511** Both styles follow Article 8.2 of that decision for two-letter nuclei: tone on the first letter of `ia`, `ua`, `ưa` (`bìa`, `lụa`, `lửa`) and on the second letter of `iê`, `yê`, `uô`, `uơ` (`biển`, `thuyền`, `nhuộm`, `được`, `thuở`). Only the three open glide pairs of 5.2 differ between the styles.

### 5.3 Placement examples

| Keys (Telex) | Traditional | Modern | Rule |
|---|---|---|---|
| `hoaf` | hòa | hoà | 3, pair `oa` |
| `hoafn` | hoàn | hoàn | 2 |
| `khoer` | khỏe | khoẻ | 3, pair `oe` |
| `thuyr` | thủy | thuỷ | 3, pair `uy` |
| `huyts` | huýt | huýt | 2 |
| `huynhf` | huỳnh | huỳnh | 2 |
| `xoays` | xoáy | xoáy | 3, three letters |
| `hoaif` | hoài | hoài | 3, three letters |
| `khuyur` | khuỷu | khuỷu | 3, three letters |
| `ngoeoj` | ngoẹo | ngoẹo | 3, three letters |
| `cuar` | của | của | 3, pair `ua` |
| `mias` | mía | mía | 3, pair `ia` |
| `muwaf` | mừa | mừa | 1 |
| `tuooir` | tuổi | tuổi | 1 |
| `ruwowuj` | rượu | rượu | 1, last modified letter |
| `hieeur` | hiểu | hiểu | 1 |
| `khuyeenr` | khuyển | khuyển | 1 |
| `hueej` | huệ | huệ | 1 |
| `quys` | quý | quý | `qu` onset |
| `giuwax` | giữa | giữa | `gi` onset, rule 1 |
| `sooocs` | soóc | soóc | 2, second `o` |

### 5.4 Relocation while typing

Because placement is recomputed on every key, the tone moves when the syllable grows or shrinks:

| Keys so far | Display | What changed |
|---|---|---|
| `h o a f` | hòa (trad) / hoà (modern) | open `oa` |
| `+ n` | hoàn | coda arrived: rule 2 |
| `g i s` | gí | `i` is the nucleus |
| `+ u` | giú | `i` became part of `gi`: tone moves to `u` |
| `+ p` | giúp | |
| `h o a f n` then Backspace | hòa (trad) | coda removed: back to rule 3 |

- **ENG-R520** Relocation MUST produce a minimal edit (section 6.3) and never leave a stray mark.

### 5.5 Horn handling for `uo`

- **ENG-R530** Within a `u o` pair of the vowel group, a horn on either letter means a horn on both in the display: `tuwong` -> `tương`, `tuwowng` -> `tương`, `tuowng` -> `tương`. The `u` of `qu` is never part of such a pair (`quơ`, `quở`).
- **ENG-R531** While typing, an open pair is shown as `ươ` (`ngươ` before `i` arrives, `thươ` before `ng` arrives).
  *Rationale: `ươ` followed by a coda or ending (`người`, `thương`, `đường`, `rượu`) is far more frequent than open `uơ`; showing `ươ` keeps the edit for the next key to a single insertion.*
- **ENG-R532** At commit, an open `ươ` (no coda, no ending) is written `uơ`, tone on `ơ`: `thuowr` + space -> `thuở`, `huow` + space -> `huơ`. A reset (section 10) commits nothing, so no edit is made in that case.
- **ENG-R533** A circumflex on the `o` of `ươ` removes both horns (`cươi` + `o` -> `cuôi`); a `w` on `uô` replaces the circumflex with horns on both (`cuối` + `w` -> `cưới`) (REG-12).
- **ENG-R534** A second `w` on a fully horned pair escapes: `thuoww` -> `thuow` (REG-12).

---

## 6. Composition model

### 6.1 Recompute from raw keys

- **ENG-R601** The display of a token MUST be a pure function of (raw keys, configuration). The recommended implementation replays the raw keys through the rules of section 4 on every event; an incremental implementation is allowed only if a property test proves it equal to replay for every generated and fuzzed sequence.
  *Rationale: replay makes restore exact (the raw keys are the source of truth), makes Telex and VNI unable to leak into each other, and turns tone relocation, Backspace and re-opened words into the same operation.*
- **ENG-R602** The token state MUST keep the raw keys exactly as typed (characters with case). Derived data (letters, tone, escape kinds, literal flag, frozen display) MAY be cached.

### 6.2 Output of one event

- **ENG-R610** For every event the engine returns one action:
  - `passThrough`: the host delivers the original key unchanged. Used whenever the new display equals the old display plus exactly the typed character, and for keys the engine does not handle.
  - `edit(delete, insert, thenPassThrough)`: the host deletes `delete` characters before the cursor, inserts `insert`, then delivers the original key if `thenPassThrough` is true (used at boundaries so that the space or punctuation reaches the app as a real key).
  - An edit with `delete = 0` and an empty `insert` means "swallow the key" (for example a second `w` that changes nothing visible).
- **ENG-R611** Edits MUST be minimal: compute the longest common prefix of the old and new display (by character), delete the rest of the old display and insert the rest of the new one.
  *Rationale: fewer synthetic deletions means fewer app glitches (autocomplete in browser address bars, spreadsheets), which were about half of all reported bugs.*

Example trace (Telex, traditional):

| Key | Action | Display |
|---|---|---|
| `v` `i` `e` | passThrough each | vie |
| `e` | edit(delete 1, insert `ê`) | viê |
| `j` | edit(delete 1, insert `ệ`) | việ |
| `t` | passThrough | việt |

| Key | Action | Display |
|---|---|---|
| `h` `o` `a` | passThrough each | hoa |
| `f` | edit(delete 2, insert `òa`) | hòa |
| `n` | edit(delete 2, insert `oàn`) | hoàn |

VNI `duoc795`: `d u o c` pass through; `7` -> edit(delete 3, insert `ươc`); `9` -> edit(delete 4, insert `đươc`); `5` -> edit(delete 2, insert `ợc`).

### 6.3 Marked-text hosts

- **ENG-R620** Every output MUST also carry `composingText`, the full display of the active token (empty when there is none), so that an input-method host can show it as marked text and commit it at the boundary instead of applying edits.

### 6.4 What "delete count" counts

- **ENG-R630** `delete` counts **user-perceived characters (extended grapheme clusters)** of text that the engine itself produced or let through for the current token and for re-opened history (section 10). The engine MUST NOT ask for deletion of anything it did not produce.
- **ENG-R631** Because the engine only emits ASCII and precomposed Vietnamese letters (all in the Basic Multilingual Plane, none combining), for every engine-produced span: grapheme clusters = Unicode scalars = UTF-16 code units. The edit MUST carry both `deleteCount` (clusters) and `deleteUTF16Count` (UTF-16 units), and a test MUST assert they are equal for every edit.
- **ENG-R632** The host maps `deleteCount` to Backspace events (one per cluster) or to a UTF-16 range for accessibility or marked-text replacement. If an app is known to normalise text to NFD (one cluster becomes several units), that is a host concern; the engine contract stays in clusters.

### 6.5 No fixed-size limits

- **ENG-R640** Raw keys, letters and history MUST use growable storage. No sequence of events may cause a trap, truncation or out-of-bounds access, whatever its length (REG-02).
- **ENG-R641** The engine MAY switch a token to literal mode once it holds more than 64 raw keys while still composing, purely to bound replay cost. No Vietnamese syllable needs more than about 15 keys. Restore stays exact because raw keys are kept in full.

---

## 7. Escape, restore and tone removal

### 7.1 Doubled keys

Defined in 4.7. Doubling is the always-available, per-key way to get a literal letter.

### 7.2 Restore toggle (host hotkey, Escape by default)

- **ENG-R701** On `restoreToggle`, when the previous event was not a `restoreToggle`: if the active token's display differs from its raw keys, the engine MUST replace the display with the raw keys (edit, key swallowed) and flag the token **user-restored** (literal for the rest of the token, never changed by commit). Otherwise, if the token is flagged restored (by a commit rule, section 8, or by the user) and its composed form differs from the raw keys it shows, the engine MUST replace the display with the composed form and flag the token **user-kept**. The raw keys a token shows are its raw keys, except for a re-opened token whose text left out its `w` doublings (`R′`, ENG-R804, written by a restore, ENG-R1005, or by the toggle that took back a correction, ENG-R1117), until a Backspace takes that doubling: it shows `R′`, so `answwer`, space, Backspace, toggle shows `ánwer` (user-kept), never `answwer`. *(Amended by the product owner's decision of 20/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 7, REG-40: until then a token showed only `R`, and both branches compared the display and the composed form with `R`.)*
- **ENG-R702** A `restoreToggle` that immediately follows another `restoreToggle` (no other event in between) MUST return `passThrough` and change nothing. A second consecutive press therefore always reaches the app with its normal meaning.
  *Rationale: a toggle that flips back and forth on every press would trap the user in Spotlight or a dialog, where Escape also means "close"; the review replaced the earlier flip-back behaviour with this rule. The Vietnamese form is still one step away: Backspace (or any other event) followed by the toggle composes the token again (E02b), and an automatic restore is undone the same way (ENG-R704), or by the toggle alone right after a restore that the words before the token decided (ENG-R706).*
- **ENG-R703** If there is no active token, or neither branch of ENG-R701 applies, `restoreToggle` MUST return `passThrough`, so the key keeps its normal meaning (closing Spotlight, dialogs, Vim insert mode), except right after a commit that changed a word by itself, where the toggle undoes that change: a restore that the words before the token decided (ENG-R706), a revision of the previous token (ENG-R829) or a typo correction (ENG-R1117). *(Amended by the product owner on 23/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 9, REG-42: until then this rule named no exception, the undo of a revision and of a correction being stated where those changes are, and the toggle right after a commit that rule L10 or L9b restored passed through: `Thanks Giving bar`, space, toggle left `bar `.)*
- **ENG-R704** To undo an automatic restore, the user presses Backspace once (re-opening the word, section 10) and then the toggle. Example: `test` + space commits `test ` (restored by rule L11); Backspace re-opens `test` in its restored state (ENG-R1005); the toggle shows `tét` and marks the token user-kept. Right after a commit whose restore the words before the token decided (rules L10 and L9b), the toggle alone undoes it (ENG-R706); Backspace then the toggle still works there and gives the same text and signals. *(Amended by the product owner on 23/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 9, REG-42: until then Backspace then the toggle was the only undo of every automatic restore.)*
- **ENG-R705** The restore of a VNI token MUST reproduce the digits typed (`vie65t` + toggle -> `vie65t`), and a Telex token the letters typed, including doubled letters (`traffic`) (REG-05, REG-27).
- **ENG-R706 Undo of a context restore.** A `restoreToggle` that immediately follows a commit (no other event in between) which restored its token because of the tokens before it MUST answer with an edit that replaces the restored keys with the composed form `C`, the text a keep would have written, the boundary character unchanged (`Thanks Giving bar`, space, toggle gives `Thanks Giving bả `); mark the token the user's choice, user-kept (rule L1 if it is re-opened); carry the learning signal of ENG-R861 (`preferredVietnamese(raw)`, the lowercased raw keys) and, for a word of the collision list, the strong signal of ENG-R864 for the Vietnamese side, exactly as Backspace, the toggle and the boundary key would (ENG-R704); and withdraw the token's weak signal (ENG-R864). The token's language for the window becomes that of its new text (ENG-R823), so `tricky as`, space, toggle, `car`, space gives `tricky á cả `. The next toggle passes through (ENG-R702).
  The restores it covers are those whose rule reads the tokens before the token, when the token alone would keep `C`: rule L10 (`restored(englishRun)`, the English run of ENG-R823) and rule L9b (`restored(phrase)`, ENG-R826), when the ambiguity row of the raw keys is `vi` (or unreviewed), or there is none and the word is not on the tech-always list, so that rule L11 would keep it. It leaves out the restores the token alone decides (L3b, L4a, L5, L8, an `en` row of L11 and the tech-always list, also when L10 or L9b decided them first: in `the best` the phrase restores `best`, which its `en` row restores anyway), because consuming the key after every restored English word would take Escape away in chat apps, browsers and dialogs; the user's own choices (L1, L2); and three rules that read the context but are no inference from the words before: L9 (a command word of a command line in the code context, ENG-R850; the rules turn the restore key off in terminals, IDEs and code editors, PLT-R353), L9c (the learned memory, the user's own earlier corrections, ENG-R863; its any-context entry reads no previous token, and the engine does not see which entry voted) and the English context of L4 (a) (the doubled key is the writer's own choice of the keys, 4.7, and L4 gives one reason code for all its outcomes). Those keep the undo of ENG-R704. What it covers is still wide, because the ambiguity table keeps many common English words alone and lets an English run restore them: its `vi` rows whose `run` column is `en` (292 rows; with `lookaheadRevision` off also the 53 whose `run` column is `vi`, which L10 then restores, ENG-R829). After an English run the toggle right after any of them is consumed. Typed after `Thanks Giving` (the census of the measurement below), 289 of the 40,715 words of the English lexicon and the tech lists are covered: those 292 rows less `chown`, `ef` and `max`, which only the code context makes English. Among them are 32 of the 150 English function words (`as`, `of`, `if`, `this`, `there`, `these`, `here`, `now`, `too`, `us`, `has`, `his`, `its`, `how`, `most`, `must`, `last`, `been`, `did`, `away`, `own`, `thus` and ten more) and words such as `car`, `bus`, `box`, `six`, `rest`, `lost`, `low`, `turn` and `tree`. A writer of English who presses Escape right after one of them for another reason, to close a dialog or a popover, gets the Vietnamese form, the key does not reach the app, and the toggle reports a Vietnamese choice like any undo (`I will be there`, space, toggle gives `I will be thể ` with `preferredVietnamese(raw: "there")` and a strong signal for the Vietnamese side, which the learned memory weighs against the word's silent acceptances as English, ENG-R863); the second press reaches the app. The scope as built is the integrator's reading of the report and waits for the product owner's confirmation against this census; leaving out the English function words, or another part of the table, would narrow it.
  The conditions mirror the revision undo of ENG-R829: after Return or Tab the history is cleared and the toggle passes through, and so does a toggle after a non-ASCII boundary character. The undo does not depend on `lookaheadRevision` or `typoCorrection`; with auto restore off, L10 and L9b restore nothing (ENG-R802) and there is nothing to undo; where the restore key is off (PLT-R353, PLT-R357) the host never sends the toggle. When the same commit also revised the previous token (ENG-R828; only RV1 meets a token that L9b restores, since RV2 to RV5 need a next token that a rule reading the token alone decides or keeps), the toggle undoes the revision as ENG-R829 says and the token's own restore stays: `has been`, space, toggle gives `há been `, and Backspace then the toggle gives `bên` (ENG-R704). One toggle answers one decision and gives at most one strong signal (ENG-R864), ENG-R829 answers as it always did, and the restored token keeps the undo of ENG-R704 while the revised token has no other one-key undo. Typing any other key instead of the toggle changes nothing: the revisions of ENG-R828 happen as before (`Thanks Giving bar voiws` gives `Thanks Giving bả với` by RV4).
  *(Added by the product owner on 23/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 9, REG-42, after typing `Thanks Giving bả với KT qua nhà ổng ở Ohio chơi` on 1.1.0-beta.1: the space restored `bar` because the two words before it are English, Escape right after passed through and, a hard boundary in the host, also took away the revision the next Vietnamese word would have made, so the line kept `bar với`. The scope (L10 and L9b when the token alone keeps `C`) and the precedence of the revision undo are the integrator's call on that report. Measured on 23/11/2026 with the bundled data, Telex, from an empty field, against the engine of 1.1.0-beta.1 (28dbd6d0), with `typoCorrection` off and on (the harness, its inputs and these figures: `Packages/VietnameseEngine/Scripts/context-restore-measure/`): in 60,000 generated lines that mix words of the English lexicon, words valid in both languages (the ambiguity table) and Telex keyings of Vietnamese syllables, with the restore key after commits, and in 1,320 lines of the 330 bundled phrases (each typed alone, after `and` and after `vieejt`, then a space and the restore key, and once followed by a Vietnamese word), every line whose text or signals differ (3,167 of the 60,000 and 296 of the 1,320, the same with `typoCorrection` on and off) holds a restore key right after a commit that this rule covers, and every line that holds one differs; the 100,000 random sequences of the `w` doubling harness (`w`, vowels, tone keys, Backspace, space and the restore key) do not differ. A line can differ after the undo too, since the undone word is Vietnamese evidence for the window: `disobeying vats swoon.` with the restore key after each word gives `disobeying vát suôn.` instead of `disobeying vats swoon.`. The harness flags a line from this rule's own condition, so these figures show that nothing outside the rule changed, not that its scope is right; for the scope, a census set types each of the 40,715 words of the English lexicon and the tech lists after `Thanks Giving` and lists the 289 that the rule covers (10 `proposed` and 279 `unreviewed` `vi` rows, 32 English function words), each of which differs while no other word does, and the flagged phrase lines hold 104 of the 330 phrases. The same holds with `lookaheadRevision` off (no L9b, no `run: vi` exemption: 3,704 mixed lines, 183 phrase lines and 342 census words differ, all flagged) and with auto restore off (no line flagged, none differs).)*

Default binding (host side, `03-product.md` D8 and PRD-R18): **Escape is bound by default**, with an on/off setting (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md; the first version left it unset). Escape is one key, free inside a word in ordinary text fields, and known to users of other input methods. The host consumes it only when the engine answers with an edit (ENG-R701, and right after a commit ENG-R706, ENG-R829 and ENG-R1117); otherwise it passes through with its normal meaning (ENG-R702, ENG-R703), so a second press always closes Spotlight or a dialog. Compatibility rules turn the binding off where Escape has its own meaning (terminals, IDEs and code editors, games, remote desktop clients: `features.restoreHotkey: false`, `02-platform.md` PLT-R353), never per-app code. The engine is unaffected: it only sees `restoreToggle` events.

### 7.3 Tone removal

`z` (Telex) and `0` (VNI) remove one layer per press (ENG-R411): the tone first; with no tone, every vowel modifier and `đ` at once (`daauszz` -> `dau`, `dduwowngfzz` -> `duong`); with neither, the key is a letter or literal digit, which also covers `qu` with no vowel and every other vowel-less token (REG-01, REG-25). Doubling still removes one modifier or the stroke by itself (`aa` + `a`, `dd` + `d`). At commit a word that ends with a removal keeps the text it left unless the raw keys are English (rule L4a, product owner, 18/11/2026, REG-39): `dduwowngfzz` + space gives `duong`. *(The first version never removed vowel modifiers or `đ` with these keys; amended by the product owner on 15/11/2026, REG-34.)*

### 7.4 Backspace inside a token

- **ENG-R710** Backspace removes the last visible character of the token. In composing mode the engine removes from the raw keys: the key that produced that letter, its modifier and stroke keys, and every tone key if the tone is displayed on that letter. Then it recomputes. In literal mode it removes the last raw key and recomputes (which may leave literal mode). A re-opened token that a commit rule restored leaves its restored state by ENG-R1005. A key that set or removed a tone, or removed letter marks (ENG-R411), never comes back as a letter: when it would replay as a letter or literal digit once the deleted letter's keys are gone, it goes too (`aaz` + Backspace leaves an empty token, `daauszz` + Backspace -> `da`: there the second `z` still finds `â` to unmark and stays). A mark removal clears every mark, so of the mark keys typed before it none gives a mark that a letter shows afterwards, not even the own key of a standalone `w` or a bracket letter (ENG-R103, ENG-R104): the shared-key rule above counts only the mark keys typed after the newest removal (`wzow` + Backspace -> `ư`: the `w` after the `z` gave the `ư` its horn and stays; VNI `u70o7` + Backspace -> `ư`).
  A modifier or stroke key goes with the deleted letter only if every letter it targeted is deleted; otherwise it stays and keeps marking the remaining letters. This matters for keys that mark two letters at once: one Telex `w` or VNI `7` on `uo` (`thuowr` + Backspace -> `thư`, not `thu`; `dduowcj` + 2 Backspaces -> `đư`). Precisely, a shared key stays only for a remaining letter that still shows the mark and has no other way to get it: when that letter also has a mark key of its own (`thuwowr`), or is the `ư` of a standalone `w` or of a bracket key (ENG-R103, ENG-R104: `wow`), the shared key goes, because keeping it would replay as an escape (`thuww`); when it has several shared keys, only the newest stays (VNI `uo76m7`: the second `7` gave the horns back after the `6`). A `u` that shows no horn loses its horn keys with the letter after it: after a circumflex replaced the horns of `ươ` (ENG-R533: `cuowio` shows `cuôi`, `cuowios` + 2 Backspaces -> `cu`), and in a word re-opened from history that shows the commit spelling `uơ` of an open `ươ` (ENG-R532, ENG-R1002: `thuowr`, space, 2 Backspaces -> `thu`).
  *History: the first version removed every modifier key that targeted the letter, so deleting `ơ` also took the horn off `ư` (`thuowr` + Backspace gave `thu`; reported by the product owner on 14/11/2026 in chat apps, "Backspace gây đổi chữ"). W243 only covered one `w` per letter.*
- **ENG-R711** If the removed letter was produced by an escape (4.7), Backspace removes the escaping key and also the earlier keys whose effect it undid, so the field loses exactly its last character and the stickiness of that kind ends because its escape is gone (ENG-R441): `boss` + Backspace -> `bo`, and one more `s` -> `bó`; `nhaamff` + Backspace -> `nhâm`, and a following `f` -> `nhầm` (the tone can be applied again, REG-24); `ass` + Backspace -> `a`; `cass` + Backspace, `o` -> `cao`; `teee` + Backspace, `e` -> `tê`, and `teee` + Backspace, `epj` -> `tệp`; `verr` + Backspace -> `ve`; `Saff` + Backspace -> `Sa`; `Quyeenff` + Backspace -> `Quyên`; `ww` + Backspace leaves an empty token. The keys an escape undid are: for a tone, every key that set or removed the tone; for a circumflex, every mark key of its letter and, on the `o` of a `u o` pair, the horn keys of the `u` whose horn the circumflex removed (ENG-R412, ENG-R533); for the stroke, the stroke keys; for a horn or breve, the mark keys of every letter it unmarked and the keys of every standalone `ư` it removed (ENG-R413); for a bracket key, the keys of the letters it removed (4.8). A bracket key's escape keeps a mark key that still marks a letter that stays (`]ow]` shows `ơ]`: the `w` gave the `ơ` its horn, so Backspace gives `ơ`). In the replay of the remaining keys, a mark removal that would now be a letter goes (ENG-R710), and a key that set or removed the tone and finds no vowel yet waits for the next letter and applies there (ENG-R432): `wsaw` + Backspace -> `á`, `wsoww` + Backspace -> `ó`, `wszaw` + Backspace -> `a` (the whole chain of tone keys waits, the removal included); a tone key that no later letter takes goes too: `WSw` (`w` after the standalone `Ư` took the tone of `S`) + Backspace leaves an empty token. A waiting key is replayed after the letter that takes it, so the restore toggle shows it there: after `wsaw` + Backspace it shows `as`, after `wsfaw` + Backspace `asf`. The result is always the old display minus its last character; when the remaining keys cannot give it, the engine falls back to it anyway, in this order: (1) a letter whose mark comes from its own key, the `ư` of a standalone `w` or the `ư` or `ơ` of a bracket key, shown unmarked because the escape removed its mark (`]w`, `[w`, `[oo`) or undid the circumflex that removed it (`wooo` shows `uoo`, Backspace gives `uo`), is kept as a `u` or `o` key, the only key that shows it unmarked, so the restore toggle shows `u` or `o` for it; (2) otherwise the token is retyped from the letters shown, each letter's key followed at once by the key of its mark and the tone key after the letter that gives the text, or no tone key when no letter shown takes it (a bracket letter shown unmarked typed as its plain letter, or as its bracket key and a mark removal), which covers a transform the remaining letters no longer allow in the order typed: `dwndw` shows `đnw` (the stroke applied while the `ư` stood) and Backspace gives `đn`, raw keys `ddn`; `]ous]` (bracket keys on) shows `óu]` and Backspace gives `óu`; `dwnsdw` shows `đnw` (the `ư` that took the tone of `s` went with the escape) and Backspace gives `đn`, raw keys `ddn`, as does `d]nsd]` with bracket keys on. The restore toggle then shows the retyped keys, and the commit rules and a learning signal (ENG-R861) see them too; they hold no escape (ENG-R441). ENG-T38 checks every key sequence of up to five keys over alphabets of transform keys, and of six keys over a smaller one, and no case outside (1) and (2) is known. *(Amended by the product owner on 15/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, which changes the decision of 14/11/2026: the first version removed only the escaping key, so the escaped effect came back, `boss` + Backspace gave `bó`, and the length could stay, `ww` + Backspace gave `ư`. In his dev traces of 16 hours it hurt three times and helped once: `cass` + Backspace, `o` gave `cáo`; `teee` + Backspace, `e` gave `tee`; `W` + Backspace gave `Ư` instead of deleting it.)*
- **ENG-R712** If the recomputed display equals the old display minus its last character, the action is `passThrough` (the app deletes the character itself). Otherwise the engine swallows the Backspace and returns an edit (for example traditional `hoàn` + Backspace -> `hòa`).
- **ENG-R713** Backspace with no active token is handled by the history rules of section 10.
- **ENG-R714** Backspace only deletes: every Backspace, inside a token or into the history, takes exactly the last character of the field and leaves every other character as it was, with these documented exceptions: (a) the tone moves to the letter the placement rule now picks (5.1, 5.2; W240); (b) the letter before the deleted one is the `ư` of a standalone `w` or of a bracket key that the field showed as `u` (a circumflex replaced its horn, ENG-R533, or a re-opened word shows the commit spelling `uơ`, ENG-R532); its own key is the only key left for it, so it shows `ư` again (`woo` shows `uô`, Backspace gives `ư`); (c) a plain `u` that showed a horn only to complete the pair with a bracket `ơ` (ENG-R530) shows `u` again when that `ơ` is deleted (`u[` shows `ươ`, Backspace gives `u`); (d) a bracket letter follows the case of the word (ENG-R906), so a deletion that changes whether the word is all caps changes its case, and (a) may apply in the same press (`]ZSOU` shows `UÓU`, Backspace gives `úO`). An escape letter is no exception: it goes with the keys it undid (ENG-R711). Neither is the key that started literal mode: the recompute of ENG-R421 gives back the display frozen before that key, so the field loses exactly its character. *(The first version listed two more exceptions: (b) an escape letter brought the escaped effect back, kept on 14/11/2026 and changed by the product owner on 15/11/2026, and (c) the recompute after deleting the key that started literal mode, which only differed from a deletion when that key was an escape.)* An edit answering a Backspace MUST NOT delete more than the active token's display (a Backspace with no active token passes through, ENG-R1002; only when the newest history entry is a token without its boundary, which a commit never leaves, does ENG-R1003 re-open it and delete into it, and the host, which saw no active token, refuses any edit that results, PLT-R352). ENG-T38 tests this property.

Examples: `vieejt` + Backspace -> `việ`, + Backspace -> `vi` (the tone goes with `ệ`); traditional `hoaf` + Backspace -> `hò` (tone was on `o`); modern `hoaf` + Backspace -> `ho` (tone was on `à`); `duwowngf` + 3 Backspaces -> `dư`; `thuowr` + Backspace -> `thư`; `truowngf` + 3 Backspaces -> `trư`; `nguowif`, space, 3 Backspaces -> `ngư`; VNI `thuo73` + Backspace -> `thư`.

---

## 8. Restore policy for English and other non-Vietnamese tokens

### 8.1 Decision at commit (normative, first matching rule wins)

Inputs: the committed display `C` (after 5.5 normalisation), the raw keys `R`, the token flags (escape used, user-restored, user-kept), the language of the previous tokens in the run (8.3), the boundary key, the previous committed tokens of the run (rule L9b), the tokens and boundary characters of the line before the token (rule L9, ENG-R850), the app context (8.6) and the resources (8.2), including the host's learned memory (ENG-R865). "R is English" means the lowercased `R` is in the English lexicon or the tech-always list. "The collision list" is the ambiguity table plus the collision supplement (8.2).

| Rule | Condition | Result |
|---|---|---|
| L0 | `C` equals `R` (nothing was transformed) | nothing to decide |
| L1 | token is user-restored or user-kept (7.2) | keep the user's choice |
| L2 | `R` in the user keep-as-typed list / keep-Vietnamese list | restore / keep |
| L3 | `C` contains no vowel letter and no escape was used in the token | keep (abbreviations such as `đc`, `ĐL`, `ĐHQG`) |
| L3b | the raw keys are camel case (ENG-R904): `useState` composes as `ueState` | restore (`R′` when the `w` doublings are a habit, ENG-R904) |
| L4 | an escape was used in the token | `C` and `R` both English: keep `C` only when the escape was a needed doubling and the context is not English, else restore; only `C` English: keep; only `R` English: restore; neither, and `R′` (`R` without its `w` doublings) English: restore `R′`; neither: keep `C` when it is a deliberate form, else restore, `R′` when the `w` doublings are a habit (every one undid the `ư` of a standalone `w`, no `w` key follows it and none is a capital right after a lowercase `w`) (ENG-R804) |
| L4a | the last key of the token is a tone-removal key (Telex `z`, VNI `0`) that removed the tone or the letter marks (ENG-R411) | restore if `R` is English, else keep `C` (product owner, 18/11/2026, REG-39) |
| L5 | `C` is invalid | restore |
| L6 | `C` is Tier B but not Tier A | restore if `R` is English, else keep |
| L7 | `R` is not English | keep |
| L8 | `C` is not in the attested-syllable list | restore |
| L9 | app context is `code`, `R` is in the code-only tech list, the token is not in Vietnamese text (ENG-R850: a Vietnamese word among the previous three tokens of the line, the previous token neither English nor a code word, a space and no code character between it and the token) and it does not start a sentence (ENG-R850: the first word of its line, in sentence case, committed by a space and not on the capitalized code-word list) | restore (for a code-only word whose raw keys are not English, evaluated right after L5, before L6 and L7, which would keep it, ENG-R801, REG-38; for the others reached only when L6 to L8 did not decide, see ENG-R850; at the start of a line RV5 may revise it when the next word commits, ENG-R828) |
| L9a | `R` is on the boundary-particle list, the boundary key is `.`, `!`, `?` or Return and the token does not continue a phrase (L9b) | keep (ENG-R825) |
| L9b | the previous 1 to 3 tokens of the run (each followed by exactly one space) plus `R`, lowercased, start a bundled phrase | restore (ENG-R826) |
| L9c | `R` is on the collision list and the learned memory votes for it in the current context class | as voted (ENG-R863) |
| L10 | the run is in English (8.3: an `en` token and no `vi` token among the previous three) and the ambiguity row of `R` has no `run: vi` mark (ENG-R827) | restore |
| L11 | ambiguity table row for `R`: `en` -> restore, `vi` -> keep; no row: restore if `R` is in the tech-always list, else keep | as stated |

- **ENG-R801** The engine MUST implement exactly this order, with one exception: for a code-only word whose raw keys are not English, L9 is evaluated right after L5, before L6 and L7, which would keep it (decided by the product owner on 18/11/2026, ENG-R850, REG-38; the first version evaluated L9 after L8 for every word); a code-only word whose raw keys are English reaches L9 in its place, after L6 and L8, which restore it on their own when they apply. It MUST include the escape condition of L3: a token in which an escape was used is never kept by L3 and is decided by L4 instead, so `www` (displayed `ww`, raw keys a tech-always word) commits as `www` and ENG-T12 holds. Each committed token MUST produce a reason code naming the rule (section 12) so that diagnostics can show "restored because invalid syllable" without storing text. *(The escape condition was confirmed by the product owner on 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md.)* L4 decides as ENG-R804 says, with the reason code `escape` for every outcome; L4a, after L4, decides with the reason code `toneRemoval` (decided by the product owner on 18/11/2026, Q9 of section 15, REG-39). *(Amended by the product owner on 17/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md: the first version read "keep `C` if `C` is an English word; else restore if `R` is English; else keep `C`", so `leecher` committed `lecher` and `turn off the light` committed `turn of the light`, REG-37.)* L9a, L9b and L9c are evaluated in that order after L9 and before L10; their reason codes are `boundaryParticle`, `phrase` and `learned`. L9c also applies to a token that L6, L7 or L8 would decide when `R` is on the collision list and the memory votes for the other side (a vote that agrees leaves the rule as it is): the memory reaches the collision supplement (`cos`, kept `có` by L7) and the generated rows that L8 restores. With `lookaheadRevision` off (ENG-R829) L9a, L9b and the `run: vi` exemption of L10 never apply; L9 reads the line before the token either way (ENG-R850).
- **ENG-R802** When auto restore is off, rules L3b to L11 MUST NOT restore anything. L1 and L2 (the user's own choices) still apply.
- **ENG-R803** A restore at commit is an edit that replaces `C` with `R` (with `R′` when rule L4 or L3b restores the keys without their `w` doublings or the token is a re-opened token that shows `R′`, ENG-R804, ENG-R904, ENG-R1005) followed by the boundary key (`thenPassThrough`); when that text is the display already (`wwebview` shows `webview` and restores `webview`), the boundary key passes through. When the commit also revises the previous token (ENG-R828), the edit covers the previous token, its separator and the current token in one `TextEdit`; the boundary key follows.
- **Typo correction (1.1.0).** After this decision, section 11A MAY replace a token that the decision would show as typed or restored, or that L6 keeps only through a place-name cluster, with the one English word that is one edit away (ENG-R1110); the edit has the shape of ENG-R803 and the reason code `corrected(rule)` names the rule above that would have decided the token (ENG-R1115). Nothing in this table changes.
- **ENG-R804 Escape at commit (rule L4).** A **doubling** is an escape whose key comes right after a key whose effect it removes (4.7: `ass`, `aaa`, `boooong`, `Karr`, `Anaa`, VNI `a11`); an escape key that comes back after other keys is not one (`costs`: the second `s` after `t` escapes the tone, ENG-R410; `leecher`: the third `e` after `ch` escapes the circumflex; `pajama`). A **`w` doubling** is a doubling by the Telex `w` key (either case) that comes right after the `w` key whose effect it removes: a horn, a breve or the `ư` of a standalone `w` (ENG-R413: `aww`, `uww`, `thuoww`, `powwow`, `ww`, `wwebview`); it is a **standalone `w` doubling** when that effect is the `ư` of a standalone `w` (`ww`, `wwebview`, `Twwitter`). The `w` doublings of a token are a **habit** when every one is a standalone `w` doubling, no `w` key comes right after it and none is a capital `W` typed right after a lowercase `w`: `www` typed as written (ENG-T12) shows `ww` and is no habit, since no English word starts with `ww` except `www` (`wwwexample` restores `wwwexample`, `wwwRoot` stays `wwwRoot`); nor is Shift for the second key alone, which the habit (`ww`, `Ww`, `WW`) never types: the screen shows that capital (`dwWidth` shows `dWidth`), and leaving it out would write a text nobody saw (`wWEBVIEW` restores `wWEBVIEW`, `WWEBVIEW` restores `WEBVIEW`). VNI has none, and with the standalone `w` off only the horn and breve doublings remain. A `w` escape makes every later `w` of the token a letter (ENG-R441), so a token holds one `w` doubling at most. `R′` is `R` without the key of each `w` doubling, every other key in its case (`wwebview` -> `webview`, `Wwebview` -> `Webview`, `answwer` -> `answer`); without a `w` doubling `R′` is `R` and the cases below decide as they did before 20/11/2026. `C` is the committed display, `R` the raw keys, "English" as in 8.1:
  (a) `C` and `R` both English: `C` is kept only when every escape of the token was a doubling, the doubling was **needed**, and the context is not English; otherwise `R` is restored. The doubling was needed when the keys of `C`, typed as a token of their own with the same configuration, resources (the learned memory left out: it decides collision words only, ENG-R877) and context, commit something other than `C`: `of` alone commits `ò` (L11), so `off` keeps `of`; `pas` alone is restored by L8 and `desert` shows `dểt` and is restored by L5, so `pass` and `dessert` are restored in every context (`tôi pass môn`). The context is English when the run is English (ENG-R823, the evidence of L10, with the English-lean words when `lookaheadRevision` is on) or, with `lookaheadRevision` on (ENG-R829), when the previous tokens and `R` start a bundled phrase (ENG-R826, the evidence of L9b): `and off`, `the mess`, `turn off the light` (`turn` is kept as `tủn` but continues the phrase `turn off`, which RV1 then restores) commit the word typed, while `off` alone, `tắt off đi` (`tắt of đi`) and `ass` keep `of` and `as`.
  (b) Only `C` English: `C` is kept in every context (`tarr` -> `tar`, `hosst` -> `host`, `ddid` -> `did`, REG-10).
  (c) Only `R` English: `R` is restored (`password`, `traffic`, `coffee`; `www` of ENG-T12; `powwow`, whose `w` doubling stays).
  (c′) Neither `C` nor `R` English, `R′` English: `R′` is restored, also when `C` is a deliberate form of (d) (`answwer` shows `ánwer`, the `s` having set the tone before the doubling, and commits `answer`; `softwware` commits `software`).
  (d) Neither English (`C`, `R` and `R′`): `C` is kept when it is a **deliberate form**: every escape was a doubling, and `C` has the shape of one syllable, at most one vowel group (a maximal run of vowel letters), as every example of 4.7 (`nhaamff` -> `nhâmf`, `boooong` -> `booong`, `sooocs` -> `soóc`, `ddd` -> `dd`, `uww` -> `uw`, `Ea Karr` -> `Ea Kar`), or the escape key is the last key of the token, so the user saw `C` and committed it as shown (`Kroong Anaa` -> `Krông Ana`, PN203). Otherwise the keys are restored: two vowel groups that went on after the escape cannot be one Vietnamese syllable (3.13) and an escape that is no doubling belongs to a word typed through (`leecher`, `cheeseburger`, `coffeehouse`, `cookout`, `beefsteak`, `pajama`, `current` without the QA-R4 hand list). The keys restored are `R′` when the `w` doublings of the token are a habit (`wwebview` -> `webview`, `wwiki` -> `wiki`, `Wwebview` -> `Webview`, `vieejt wwebview` -> `việt webview`), else `R` (`dowwnload`, `bowwow`). Writers used to input methods where `w` alone gives `ư` type a word that starts with `w` as `ww`; the display shows the word, because the escaped `w` is no Vietnamese letter and the token is literal from it (ENG-R420, ENG-R442), and the escaped letter is a capital when either `w` key is one (ENG-R903), so `C` is `R′` (`Wwebview` shows `Webview`); only `wW`, which is no habit, shows a capital that `R′` leaves out. No English word starts with `ww` except `www`, which (c) decides. English writes `ww` only after a vowel, in compounds (57 words of `/usr/share/dict/words`, all after `o`, `a` or `e`: `glowworm`, `bowwow`, `arrowwood`; only `powwow` and its forms are in the bundled lexicon), and a `w` after a vowel is a horn or breve doubling, so those compounds outside the lexicon keep `R` (`bowwow`, `cowweed`).
  Known costs: a one-syllable English word outside the lexicon that ends with a doubled tone key keeps its escaped form (`riff` -> `rif`, `truss` -> `trus`), because it has the shape of the deliberate `Karr` -> `Kar`; so does an escaped form that is itself English (`posse` -> `pose`, (b)); and a word restored by (a) or (c) is English evidence for the run like any restored token (ENG-R823), so from an empty field `pass moon` keeps `moon` (`môn` has no `run: vi` mark), as `pas moon` did before. The English context of (a) looks back only, and the revisions of ENG-R828 do not take a token decided by L4, so a word whose previous token is neutral or Vietnamese keeps the deliberate escape even when the words after it are English: `ok off`, `50% off`, and at the start of a field `mess up`, `off topic`, `Off the record` commit `ok of`, `50% of`, `mes up`, `of topic`, `Of the record` (`log off`, `sign off`, `take off`, `what a mess` and `get 50% off today` commit the word typed, and so do `day off`, `sale off` and `a mess`, bundled phrases since 18/11/2026: `Ê có sale off`, `xin day off`; the product owner left `mess up`, `off topic` and `Off the record` for a later decision and ruled out a rule for `50% off` and `ok off`). A key between the key an escape undoes and the escape breaks the doubling even when it adds no letter: the chat elongation `theesee` (the tone before the extra `e`) restores the keys while `thesee` keeps `thée`, neither being the intended `thếee`; counting such a key as part of the doubling would keep `théee`, but 59 words of `/usr/share/dict/words` outside the lexicon would then commit an escaped form (`referent` -> `rẻent`, `samsara` -> `sảma`, `menses` -> `mêns`, `reefer` -> `rèer`). *(Added by the product owner on 17/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, REG-37, who chose "by context" for (a); the other parts and the doubling follow from the product owner's report that `leecher` committed `lecher`.)*
  Known costs of the `w` doubling (measured on 20/11/2026 with the bundled data, Telex, from an empty field, then a space): a doubling that undid a horn or a breve keeps `R` when `R′` is not English, so a word outside the lexicon typed with the habit after a vowel commits both `w` (`dowwnload`: `download` is not in the lexicon; of the 1,705 words of the lexicon that contain a `w` but do not start with one, typed with every `w` doubled and typo correction off, 681 commit the word, 659 before the amendment); a second `w` typed doubled in the same token stays doubled, since the first escape made every later `w` a letter (`swwalloww` commits `swalloww`, `swwalloww` before). A re-opened token that shows `R′` is decided again on its raw keys at the boundary (ENG-R1005), and a restore of it writes `R′`, the keys it shows, whatever rule restores it: `answwer`, space, two Backspaces, space gives `answe `, with `typoCorrection` on or off; a commit that keeps `C` composes the keys as for any re-opened token (`answwer`, space, three Backspaces, space gives `ánw `, a deliberate form whose escape is the last key). Once a Backspace took the `w` doubling the token does not show, the token shows every raw key again, and a `w` doubling typed after it is on screen and decided like the same keys typed afresh (`answwer`, space, four Backspaces, `wwere`, space gives `answwere `; four Backspaces, `wwer`, space gives `answer ` by (c′), as `answwer` does). *(Amended by the product owner on 20/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 7, REG-40: until then the definitions of the `w` doubling and `R′` and case (c′) did not exist and (d) restored `R` with both `w`, so `wwebview`, which shows `webview`, committed `wwebview` on 1.0.1-beta.2, and so did `wwebsite`, `wwebhook`, `wwiki`, `wwidget`, `wwechat`, `wwordpress`, `Wwebview` and `vieejt wwebview`. Measured on 20/11/2026: every word of `/usr/share/dict/words` (235,976) typed as written commits the same text before and after, with `typoCorrection` on and off, the 57 words with `ww` included (17 of them hold a `w` doubling, none a standalone one, and every one is restored as typed by (c) or (d)); of its 3,947 words that start with `w` or `W`, typed with the habit (`w` -> `ww`, `W` -> `Ww`), 3,913 commit the word with `typoCorrection` off, 795 before, the other 34 being capitalised words that committed in lowercase until REG-41 (below), and with the correction on 123 of them are corrected to another word exactly as each is when typed with one `w` (ENG-T53: `wacken` -> `waken`); the 1,096 words of the lexicon that start with `w` commit the word before and after, by (b).)* *(Amended by the product owner on 22/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 8, REG-41: until then these costs also held a capitalised word typed `Ww`, which committed in lowercase when the lowercase word is English or one syllable, because the escape appended its own key, a lowercase `w` (4.7), and (b) or the deliberate form kept `C` (`Wwade` -> `wade`, `Wwarden` -> `warden`: 34 of the 337 capitalised words of `/usr/share/dict/words` that start with `W`). The escaped letter of a standalone `w` doubling now takes the capital of the `ư` it removed (ENG-R903), so `C` is `Wade`; no rule of 8.1 changed. Measured on 22/11/2026 with the bundled data, Telex, from an empty field, then a space, against the engine of 20/11/2026 (0fdb9d98), with `typoCorrection` off and on (the harness, its inputs and these figures: `Packages/VietnameseEngine/Scripts/w-doubling-measure/`): every word of `/usr/share/dict/words` typed as written, its 57 words with `ww` typed as written and with every `w` doubled, and the 1,705 words of the lexicon that contain a `w` but do not start with one typed with every `w` doubled commit the same text; of the 3,947 words that start with `w` or `W` typed with the habit, 3,947 commit the word with `typoCorrection` off (3,913 before) and 3,824 with it on (3,790 before), the other 123 being corrected to another word exactly as each is when typed with one `w` (`Wayne` -> `Wane`, ENG-T53); the 34 words that changed are the capitalised words above, and no word that starts with a lowercase `w` changed. In 100,000 random key sequences of `w`, `W`, vowels, tone keys, a few consonants, Backspace, space and the restore key, every sequence whose text differs after some event (2,396) holds a capital `W` whose `ư` a lowercase `w` escaped. Known cost of the amendment: a `Ww` that is not word-initial keeps its capital too, so a Shift held over the first `w` after a capital letter no longer comes out as the capitalised word: `TWwitter` gives `TWitter` (`Twitter` before), `DWwell` gives `DWell`, `Wwww` gives `Www` (`www` before) and `WwADE` gives `WADE` (`wADE` before); of the 1,705 words of the lexicon that contain a `w` but do not start with one, typed with a capital first letter and every `w` as `Ww`, 239 commit differently, all of them with the `w` second and only in that letter's case, with `typoCorrection` off and on.)*

### 8.2 Data: what ships, from where, under which licence

All data is bundled in the app and loaded at start. Nothing is downloaded (ENG-R106).

| Resource | Content | Source and licence | Notes |
|---|---|---|---|
| English lexicon | Common English words, lowercase, ASCII letters only | SCOWL (Kevin Atkinson), size levels up to 35 (VERIFY final level by measuring collisions), American and British variants. Licence: permissive MIT/X11-style notice that must be reproduced in documentation; most component lists are public domain. VERIFY: the readme states that some lists used COCA-derived data under an NDA "within the rights given"; confirm the chosen levels are redistributable. Alternatives: 12dicts by Alan Beale (public domain), ENABLE (public domain). | Only membership matters, not frequency. |
| Tech-always list | Words with no common Vietnamese reading that should always stay as typed: `www`, `http`, `https`, `wifi`, `usb`, `ios`, `macos`, `json`, `html`, `api`, `url`, `a4`, `mp3`, `mp4`, `4g`, `5g`, `h2o`, brand and product names... | Written by the project, licensed with the engine. | Reviewed by Pa. |
| Code-only tech list | Shell commands and flags that collide with Vietnamese: `tar`, `less`, `more`, `cat`, `top`, `make`, `sed`, `awk`, `chown`, `ef`... | Written by the project. | Used only in the `code` context, outside Vietnamese text (L9, ENG-R850), whether or not the word is English. |
| Capitalized code words | Code-only words that configuration and protocol text writes capitalized at the start of a line: `host` (`Host github.com` starts a block of `~/.ssh/config`, `Host: example.com` is an HTTP header), 1 entry | Written by the project; the list holds only `host` (product owner, 16/11/2026). The build fails when an entry is not on the code-only tech list. | L9 still restores these words at a line start in sentence case (ENG-R850). |
| Attested syllables | Vietnamese syllables (with tone) that actually occur | Built by a reproducible script from legally safe text: Vietnamese legal normative documents (VERIFY: Vietnam IP Law 2005, Article 15, excludes legal normative and administrative documents from copyright protection), plus syllables added by Pa. MUST NOT use hunspell-vi or the Aspell Vietnamese list (GPL), Wiktionary (CC BY-SA), or data from any other input method. | Used only by L8, never to block typing. |
| Ambiguity table | Rows `raw -> vi or en` for English words whose Telex typing produces an attested Vietnamese syllable, with the columns `run` (`en` or `vi`) and `viKind` (`particle`, `function`, `content`) of ENG-R827 | Generated candidate list (8.3), each row decided by Pa; `run` and `viKind` proposed by the W11 research (15/11/2026), reviewed by Pa. | Decides L11; `run` L10; `viKind` RV3, RV4. |
| Phrases | English multiword expressions of 2 to 4 words that contain a collision word (`such as`, `has been`, `as hell`; `day off`, `sale off` and `a mess` added by the product owner on 18/11/2026), 330 entries | Written by the project from general English usage, reviewed by Pa. The build fails when a phrase's Vietnamese reading occurs in the prose corpus (13.4). | L9b, RV1 (ENG-R826). |
| Collision supplement | English and tech words outside the English lexicon whose Telex display is an attested syllable (`cos có`, `gif gì`, `nos nó`), 34 entries | Written by the project, reviewed by Pa. The build checks the display, the attestation and that the word is not English. | The memory only (L9c, ENG-R863). |
| Boundary particles | `as` | Written by the project; the list holds only `as` (product owner, 15/11/2026). | L9a (ENG-R825). |
| English function words | 150 closed-class English words (articles, pronouns, auxiliaries, prepositions, conjunctions, determiners, `lets`, `thats`, `theres`) | Written by the project, reviewed by Pa. | RV3, RV4 (ENG-R828). |
| English-lean words | `the i my he she we by be then them me am` | Written by the project, reviewed by Pa. | The window (ENG-R823). |
| Vietnamese tail words | 63 clause-final particles and adverbs (`nha`, `rồi`, `quá`); the 31 particles among them are marked | Written by the project, reviewed by Pa. | RV2 (particles), RV4 (ENG-R828). |
| English pre-guard | 44 determiners, pronouns and auxiliaries (`the`, `you`, `has`) | Written by the project, reviewed by Pa. | RV4 (ENG-R828). |

Do **not** use: wordfreq data (CC BY-SA 4.0), google-10000-english (derived from an LDC corpus; its own licence file advises against commercial use), hunspell-vi (GPL).

- **ENG-R810** Each resource MUST be built by a script in the repository from pinned inputs with recorded checksums, and the build output MUST be byte-reproducible.
- **ENG-R811** The app MUST show the SCOWL notice (and any other required notice) in its acknowledgements.
- **ENG-R812** The engine core MUST NOT embed the data; the data target provides it (section 12.1), so the core stays small and testable with tiny fixtures.

### 8.3 Ambiguity policy (words valid in both languages)

Some English words type as real Vietnamese syllables: `as` -> `á`, `is` -> `í`, `was` -> `ứa`, `has` -> `há`, `its` -> `ít`, `us` -> `ú`, `of` -> `ò`, `or` -> `ỏ`, `if` -> `ì`, `this` -> `thí`, `these` -> `thế`, `there` -> `thể`, `been` -> `bên`, `car` -> `cả`, `test` -> `tét`, `best` -> `bét`, `list` -> `lít`, `max` -> `mã`, `did` -> `đi`, `theme` -> `thêm`, `now` -> `nơ`, `how` -> `hơ`, `low` -> `lơ`. Words like `me`, `to`, `no`, `in`, `on`, `an` contain no transform key and are never an issue.

- **ENG-R820 Generation.** A build-time tool types every word of the English lexicon and the tech lists through the engine (Telex, default options, traditional and modern) and lists the words whose display is an attested Tier A syllable. That list is the candidate set for the ambiguity table.
- **ENG-R821 Decision.** Every candidate becomes a row of the table with `vi` or `en`. Rows nobody has reviewed yet are marked unreviewed and behave as `vi` (never damage Vietnamese). Pa reviews at least the 300 most frequent candidates before v1. Proposed starting decisions (Pa to confirm):

  | Raw | Display | Proposed | Why |
  |---|---|---|---|
  | as | á | vi | Southern particle, very common in chat |
  | is | í | en | rarely typed alone in Vietnamese |
  | was | ứa | en | `ứa` is rare |
  | has | há | vi | `há miệng`, `há hốc` |
  | its | ít | vi | `ít` is very common |
  | this | thí | vi | `thí sinh`, `thí nghiệm` |
  | these, there | thế, thể | vi | very common Vietnamese |
  | been, car | bên, cả | vi | very common Vietnamese |
  | test | tét | en | constant in tech chat; `bánh tét` can be typed `tets` |
  | best, list, cost, room | bét, lít, cót, rôm | en | English is the likelier intent; Vietnamese typable with tone at the end |
  | did, theme, max | đi, thêm, mã | vi | very common Vietnamese |

- **ENG-R822 Entry order matters.** The table is keyed by the exact raw keys, so a Vietnamese word blocked by an `en` row stays typable with another order: `tets` -> `tét` (L7, raw is not English).
- **ENG-R823 English run.** The language of a committed token is, first match wins: `en` if it was restored (by the user or by a rule); `neutral` if rule L11 kept it (its raw keys are an English word and its display an attested syllable, kept by a `vi` row or by the unreviewed default, for example `thí`, `cả`, `á`, `tả`; with auto restore off, ENG-R802, also a token an `en` row would have restored, so `test and this` keeps `this` by `kept(englishRun)` as the auto-restore-on run restores it): such a token is evidence of neither language; `vi` if its committed text contains a Vietnamese-only letter (`ă â đ ê ô ơ ư` or any toned vowel); `en` if it is an unchanged ASCII word that is in the English lexicon and is not a valid Vietnamese syllable (`the` is valid Vietnamese, `and` and `you` are not); `en` also if it is an unchanged ASCII word on the English-lean list (8.2), such as `the`, `my`, `he`: these are valid Vietnamese syllables but rare as unmarked Vietnamese in chat (with `lookaheadRevision` on, ENG-R829); `neutral` otherwise (digits, `a`; `the` and `I` with the switch off). A token kept by L9a, by L9c on the Vietnamese side, or by L9b with auto restore off is `neutral` like an L11 keep. The language of a revised token (ENG-R828) replaces the language it had (`en` when the revision restores it, `neutral` when it takes its Vietnamese display), so later windows see the revision. The user's own choices (L1, L2) are evidence like any other token. The run is in English when the previous three committed tokens of the run contain at least one `en` token and no `vi` token: one Vietnamese token in that window means the writer is in Vietnamese and the English token is a loanword, so L10 does not apply and L11 decides. In an English run, rule L10 restores every remaining collision. Examples, Telex from an empty field: `this is the best car` gives `this is the best car` (`thí` is neutral, `is` is restored by its `en` row, then `best` and `car` are in an English run, and the phrase `this is` revises the first word, ENG-R828; with the 13.9 fixtures, which have no phrase list, the first word stays `thí`); `I think this is as good as it gets` and `tricky as hell` stay as typed; `This is as good` gives `This is as good` (`Thí` with the 13.9 fixtures); `Khusc caif cacs app caafn thieest treen win cungx tricky as.` gives `Khúc cài các app cần thiết trên win cũng tricky á.` (`cũng` is in the window of `as`); `dduwowcj as.` gives `được á.`; `treen server been kia` gives `trên server bên kia`. *(Amended by the product owner on 14/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, REG-32: the first version made the run English when the nearest non-neutral token of the window was `en` and counted L11 keeps as `vi`, so any collision right after an English loanword was restored, `cũng tricky á` became `cũng tricky as`. The amended rule only removes L10 restores, it never adds one. Known costs (the English-lean list of 15/11/2026 removes the first one at a line start: `The cả` becomes `The car`): an ambiguous word within three tokens after a switch from Vietnamese to English stays Vietnamese, `tôi nghĩ the best car` gives `cả`; and because an L11 keep is neutral, a sentence can switch to English with no new English token once the Vietnamese one leaves the window, `vieejt and nam this as` gives `việt and nam thí as`, as the first version did for `as`.)*
- **ENG-R824 Revision of the previous token.** When token t+1 commits, token t MAY be revised once, by the rules of ENG-R828, as part of t+1's commit edit. Nothing older than t is ever changed. *(The first version left retroactive correction out of v1; the product owner asked on 15/11/2026 that the next word decide a collision word, `tricky á nha` and `tricky as hell`, docs/decisions/0005-pa-decisions-2026-11-13.md.)*
- **ENG-R825 Boundary particle.** A collision whose lowercased raw keys are on the boundary-particle list (bundled, 8.2; v1: `as`) keeps its Vietnamese display when its boundary key is `.`, `!`, `?` or Return, whatever the window says, and is neutral for the window (rule L9a). An ellipsis is three `.` keys and the first one commits the token. A token that continues a phrase (ENG-R826) is not a boundary particle: L9b decides it, so `such as.` stays English. Rationale: `tricky as.` is `tricky á.`; `has` and `did` are not on the list because `Yes she has.` and `Yes I did.` are English.
- **ENG-R826 Phrases.** Resources carry the bundled phrase list (8.2): English multiword expressions of 2 to 4 words that contain a collision word. At commit, if for some p in 1...3 the previous p committed tokens of the run, each followed by exactly one space, together with the current token form the first p+1 words of a phrase (lowercased raw keys), the token is restored (L9b, reason `phrase`) and counts as `en`. Examples: `such as`, `has been`, `me too`, the second `as` of `as soon as`. Lookups are hash lookups on preallocated tables (ENG-R1232).
- **ENG-R827 Run exemption, English-lean words, word kinds.** The ambiguity table carries two more columns: `run` (`en` or `vi`; `vi` means rule L10 never restores the word, only L9b, ENG-R828 or the memory can: common Vietnamese, rare English, such as `tows` -> `tớ`, `seeps` -> `sếp`, `teen` -> `tên`) and `viKind` (`particle`, `function`, `content`: the kind of the Vietnamese reading). Resources also carry the English-lean list (ENG-R823), the English function-word list, the tail-word list with its particle subset and the pre-guard list (ENG-R828). All are bundled, built from pinned inputs (ENG-R810) and reviewed by the product owner. New rows of the table start as `run: en`, `viKind: content`.
- **ENG-R828 Revision rules.** Preconditions, all required: t was decided by L9c, L10 or L11 for RV1 to RV4, or restored by L9 for RV5 (never L1, L2, L9a, L9b or a previous revision); t is followed by exactly one space; no reset, Backspace into the history, restore toggle or macro expansion happened between the two commits (a Backspace inside t+1 is allowed); the configuration has auto restore on, and `lookaheadRevision` on for RV1 to RV4 or `lineStartRevision` on in the code context for RV5 (ENG-R829). The first matching rule wins; a revised token is never revised again and its new language feeds the window (ENG-R823).
  RV1 (phrase, looking forward): t shows its Vietnamese display, and the up to two tokens before t (each followed by one space), t and t+1 (lowercased raw keys) are the first two or more words of a bundled phrase: restore t.
  RV2 (particle tail): t is a boundary-particle word restored by L10 or L9c, its ambiguity row is not `en`, it is not a tech-always word, t+1 is decided by a rule that reads the token alone (not L9a to L11) and t+1's committed text, lowercased, is on the tail-word list's particle subset: t takes its Vietnamese display.
  RV3 (English function word next): t shows its Vietnamese display, t's `viKind` is not `particle`, t+1 is strict English evidence (decided by a rule that reads the token alone, never L4 or L8; raw keys English; typed unchanged or restored; its display not a valid Vietnamese syllable; not all caps) and t+1's lowercased raw keys are on the English function-word list and are not `it`: restore t.
  RV4 (Vietnamese content next): t was restored by L10 or L9c, its row is not `en` and it is not a tech-always word; t+1 is Vietnamese evidence (kept by L7 with a Vietnamese-only letter, or typed unchanged as a Tier A syllable of at least two letters whose raw keys are not English and not all caps); t+1's committed text, lowercased, is not on the tail-word list; t is on the English function-word list or its `viKind` is `particle` or `function`; and the token before t, when exactly one space separates them, is not on the pre-guard list unless it shows a Vietnamese collision display: t takes its Vietnamese display.
  RV5 (code word at a line start, Vietnamese next; code context only, ENG-R850): t was restored by L9 as the first word of its line (the line start of ENG-R850 (d): no token committed since the start of the input, Return, Tab, a reset, or a Backspace that emptied the line, and before t only spaces and the openers of prose, such as an indent, a quote or a list or comment marker; so L9 restored t only because no word came before it, never after an English word, a code word, a code character, a path or a number; a reset in the middle of a line, a click or a focus change, also empties the history, the blind spot L9 itself has there); the decision the rules after L9 give t, as in `general` (L9a to L11 with t's own run, window and memory class, taken at t's commit), keeps its Vietnamese display (a word whose ambiguity row is `en`, that L10 would restore or that the memory votes English for is never revised); t+1 is kept by L7 with a Vietnamese-only letter (the first half of RV4's evidence: a syllable typed unchanged is as often a host, user or branch name, `host minh`, `host anh 8.8.8.8`); and the key that commits t+1 is a space, Return, `,`, `!` or `?` (never `.`, `-`, `/`, `_` or another character of a file name or path, so `tee nhật.log` and `tee nhật-ký.log` stay commands, and never Tab, which completes a file name in a shell): t takes its Vietnamese display, with its case (`tar thuwr` gives `tả thử`, `Host nayf` gives `Hót này`). The case of t never widens this evidence: a word in sentence case that starts a line and is committed by a space is not restored by L9 at all unless it is on the capitalized code-word list (ENG-R850), so RV5 meets lowercase and all-caps words (`TAR thuwr` gives `TẢ thử`) and the capitalized code words, before which a syllable typed unchanged is a host name (`Host minh` keeps the keys). RV5, L9a and the sentence condition of L9 (ENG-R850) are the only rules that read a boundary key (13.9.1): the decision of t+1 itself is the same at every key. *(Added after the product owner's retest of 16/11/2026, REG-36, docs/decisions/0005-pa-decisions-2026-11-13.md. A widening by a capital first letter, added after a review the same day, was withdrawn when the product owner's rule of 16/11/2026 took words in sentence case at a line start out of L9, ENG-R850: for `Tar` and `Tee` it became moot, and for `Host` it is what must not happen.)*
  The revision's reason codes are `phrase`, `particleTail`, `nextEnglish`, `nextVietnamese`, `lineVietnamese` (`EngineOutput.revision`). Examples (13.9.3, 13.9.4): `tricky as hell` (RV1), `tricky á nha` (RV2), `If you cần quyền admin` (RV3), `Great job cả nhóm` (RV4), `tả thử cái này` in a terminal (RV5); not revised: `I parked the car rồi` (tail word), `Have you been ở Đà Lạt` (pre-guard `you`), `Ngon á but mắc` (particle, RV3), `tar xf bản.tar`, `host minh`, `Host minh` and `tar thử.` (RV5). A revision deletes at most t, the space after it and t+1's display (checked by the fuzz invariant checker).
- **ENG-R829 Undo and configuration.** `EngineConfiguration.lookaheadRevision` (default true) enables L9a, L9b, the `run: vi` exemption of L10, the English-lean words of ENG-R823, the phrase evidence of L4 (ENG-R804) and RV1 to RV4 of ENG-R828; off, the engine decides exactly as it did without them (the existing corpora pass unchanged with it off). The host passes the app's effective value (`02-platform.md`). `EngineConfiguration.lineStartRevision` (default true) enables RV5 in the code context and does not depend on `lookaheadRevision`: the rules turn `lookaheadRevision` off in every code-context app, where the restore key is off (PLT-R357), while RV5 only completes rule L9's own line condition (ENG-R850); the host passes the user's D29 switch alone. Where the restore key is off, an RV5 revision cannot be undone with it; the escape by doubling (`tarr` gives `tar`, 4.7) and the keep-as-typed list (L2) keep the keys. The learned memory (L9c) is governed by `Resources.collisionMemory` (empty: no vote) and the signals of ENG-R864 are emitted either way. A `restoreToggle` that immediately follows a commit which revised t MUST answer with an edit that puts t's previous text back (t+1, the space and the boundary character unchanged), mark t as the user's choice (rule L1 if it is re-opened) and emit a strong signal for the side t showed first (ENG-R864); the next toggle passes through (ENG-R702). After Return or Tab the history is cleared and the toggle passes through, and so does a toggle after a non-ASCII boundary character. The toggle right after a commit that restored its token because of the tokens before it undoes that restore (ENG-R706, REG-42); when one commit revised t and so restored t+1 (RV1 and rule L9b), the toggle undoes the revision.

### 8.4 When restore happens

- **ENG-R830** Restore decisions MUST be made only at commit (a boundary key). There is no mid-word "instant restore".
  *Rationale: mid-word decisions cannot know the rest of the word; literal mode (4.5) already stops further marking as soon as a word is impossible, which removes the flicker that mattered (double marks).*
- **ENG-R831** A reset commits nothing and restores nothing (section 10).
- **ENG-R832** Restore MUST behave the same for the first word typed after focusing a field as for any other word (REG-18).

### 8.5 Tokens that are never restored

- **ENG-R840** Tokens with no vowel letter and no escape (L3): `đc`, `đt`, `ĐL`, `ĐHQG`, `ĐBSCL` (REG-17).
- **ENG-R841** Tokens the user toggled (L1).
- **ENG-R842** Tokens whose display equals their raw keys (L0).
- **ENG-R843** Valid Vietnamese typed in Vietnamese context, unless the exact raw keys are an `en` row of the reviewed ambiguity table or the user list says otherwise. Words in Tier B (`Krông`, `Đắk`, `Lắk`, `quởn`) and Tier A (`Buôn Ma Thuột`, `Pắc`, `huơ`, `huých`, `huỵch`, `pía`, `giếc`) are kept (REG-08).

### 8.6 App context (host-supplied)

- **ENG-R850** The configuration carries `appContext`: `general` (default) or `code` (terminals, IDEs and code editors, chosen by the host). In `code`, rule L9 restores code-only tech words (`tar` -> `tar` instead of `tả`) outside Vietnamese text, unless the word starts a sentence. Terminals and editors carry Vietnamese prose as well as commands (prompts to command-line assistants, commit messages, chat, code comments), so L9 follows the line, not the app. The line before a token is its history (section 10): it starts empty, and Return, Tab and a reset clear it. A token is in Vietnamese text when all three hold:
  (a) a Vietnamese word stands among the previous three tokens of the line: a token of language `vi` (ENG-R823), or a Vietnamese syllable typed unchanged, that is a Tier A syllable of at least two letters whose raw keys are not English and not all caps, the Vietnamese evidence of RV4 (ENG-R828): `anh`, `chim`, `tay`;
  (b) the previous token is neither English (`en`, ENG-R823) nor a code-only word shown as typed (typed unchanged or restored, such as `sudo` and `chown` at the start of a line; `chown` kept as `chơn` by L7 in Vietnamese text is a Vietnamese word);
  (c) the boundary characters between the previous token and this one hold a space (U+0020 or the no-break space U+00A0) and no code character. A word glued to the previous one with no space between them is a code join, a file, directory or user name, not Vietnamese text: `anh.tar.gz`, `anh/tar`, `minh@host` (in prose a word is never glued to the next one by `.`, `/` or `@`). The code characters are the backquote (a Markdown code span, shell substitution), the vertical bar (a pipe), `&` and `$`. Quotes, brackets, `. , ; : ! ?`, the hyphen and the slash followed by a space are prose punctuation and change nothing.
  A token starts a sentence, and L9 does not apply to it either, when all four hold *(product owner, 16/11/2026: shell commands are typed in lowercase, so a capital first letter at the start of a line is itself a sign of a Vietnamese sentence; `Tar` is not a command)*:
  (d) it is the first word of its line, the line start that RV5 of ENG-R828 shares: no token stands in the engine's history when it commits (the start of the input, Return, Tab, a reset, or a Backspace that emptied the line), and the characters typed since, if any, are only spaces (U+0020) and the openers of prose, at most 63 of them: the straight quotes, the opening curly quotes `“` and `‘`, `(`, `[`, and the markers of Markdown lists, headings and block quotes and of comments, `-`, `*`, `#`, `>` and `/` (`"Tar`, `(Tar`, `- Tar`, `# Tar`, `// Tar`, an indented `Tar`); a code character, a path, a tag, a mention or a number before the word keeps L9 (`| Tee`, `./Tar`, `<Tar`, `@Tar`, `1. Tar`);
  (e) its raw keys are written in sentence case: the first letter uppercase, every other letter lowercase, at least two letters (`Tar`, `Tee`; not `TAR`, `TAr` or `tar`);
  (f) a space (U+0020) commits it, so `Tee-Object`, `Host:`, `Tar.` and `Tar` at the end of a line keep L9; the no-break space (U+00A0, Option+Space) is not such a space, here and in (d), because a shell does not split words on it (`Tar` and a no-break space is one command name), while (c) counts it as the space of prose between two words;
  (g) its lowercased raw keys are not on the capitalized code-word list (8.2; v1: `host`, because `Host github.com` starts a block of `~/.ssh/config` and `Host: example.com` is an HTTP header).
  Such a token is decided by the rules after L9, as in `general`, at its own commit and with the reason those rules give, with one difference: a capital at the start of a line opens a new sentence, so the English run of the lines before, which survives Return (ENG-R823), does not reach it, and L10 does not restore it. `Tar` gives `Tả` and `Tee` gives `Tê` (L11 with the bundled data), `Tar thuwr cais nayf` gives `Tả thử cái này` before `thử` is typed, and so it does on the line after an English command (`git status`, Return, `Tar thuwr cais nayf`), where `general` keeps `Tar` by L10. The condition is part of L9, not a revision: no later word is awaited, it depends neither on D29 (`lineStartRevision`) nor on `lookaheadRevision` (ENG-R829), and the restore at commit and the restore key behave as for any kept token. A capitalized code word and every word that is not in sentence case keep L9, and RV5 with its own evidence (`Host minh` and `host minh` keep the keys, `Host nayf` gives `Hót này`).
  So L9 restores at the start of the input or of a line (`tar -xzf`, `TAR`, `Host github.com`, `Tar.`; RV5 of ENG-R828 gives such a word its Vietnamese display when the next word shows Vietnamese text, `tar thuwr` gives `tả thử`), after a code word (`sudo tar`), after an English word (`and tar`), after a code character (`echo "xong" | tee`, a backquote before `tar`), after a word it is glued to (`cp anh.tar.gz`, `ssh minh@host`) and when no Vietnamese word stands among the last three tokens (`ssh -p 22 host`). In Vietnamese text the rules after L9 decide exactly as in `general`: `chinhs tar` gives `chính tả`, `moo tar` gives `mô tả`, `tay tee` gives `tay tê`, and the learned memory (L9c) and the revisions (ENG-R828) apply as anywhere else. The boundary key that ends the token is not evidence, as for every rule but L9a, except the space that a sentence needs (P0-3, 13.9.1): `chinhs tar"` gives `chính tả"`, `tar"` at the start of a line gives `tar"`, and `Tar"` gives `Tar"` while `Tar` and a space give `Tả `. The conditions read only the history, the token languages, the case of the raw keys and the key that commits the token, which exist with `lookaheadRevision` off (ENG-R829); the switch changes them only through the English-lean words of ENG-R823 (`the` and `my` are English with the switch on and neutral with it off). The amended rule only removes L9 restores, it never adds one.
  For a code-only word whose raw keys are not English (neither in the English lexicon nor on the tech-always list), L9 is evaluated right after L5, before L6 and L7 (8.1, ENG-R801); a code-only word whose raw keys are English reaches it after L8, where L6 and L8 would restore it anyway. So L9 decides every code-only word whose display differs from its keys and is a syllable that no earlier rule restores: with the bundled data, Telex `host`, `tar` and `tee` (`hót`, `tả`, `tê`), whose keys are English, and `awk`, `chown` and `ef` (`ăk`, `chơn`, `è`), whose keys are not (the other words of the list are typed unchanged, show no syllable, which L5 restores, or are English words that L6 or L8 restore, `ax`, `gawk`, `more`); VNI never reaches it (its letters are plain, and the code-only words with digits compose no syllable). A code-only word whose keys are not English follows the line exactly as `tar` does: `sudo chown -R`, `ls; chown` and `ps -ef` keep the keys, `chown` at the start of a line keeps them until RV5 revises it before a Vietnamese word (`chown thuwr` gives `chơn thử`), `Chown` in sentence case at a line start gives `Chơn`, and in Vietnamese text the rules after L9 keep the Vietnamese display as in `general` (`tay chown` gives `tay chơn` by L7, `vieejt awk` gives `việt ăk` by L6); `general` keeps `chơn`, `è` and `ăk` everywhere. *(Decided by the product owner on 18/11/2026, REG-38, which closes the open point recorded in docs/decisions/0005-pa-decisions-2026-11-13.md, "Found while applying the decisions": the first version evaluated L9 after L8, so L6 and L7 decided a code-only word whose keys are not English before L9 was reached, and in a terminal `sudo chown -R` committed `sudo chơn -R`; the change reaches only code-only words, only in `code` and only outside Vietnamese text.)* Known costs: a line that starts with `tả`, `tê` or `hót` (or, since 18/11/2026, `chơn`, `è` or `ăk`) typed in lowercase or all caps, or with `Hót`, shows the keys as typed until the next word commits, then follows it (RV5, ENG-R828): `tar thuwr cais nayf` gives `tả thử cái này`; the keys stay on a one-word line, before a next word that is not Vietnamese (`tar xf`), before a syllable typed unchanged (`host minh` and `Host minh`, and so also the sentences `tar anh ấy` and `tee tay quá` typed without a capital) or before a period (`tar thử.`), before a next word whose raw keys are also English (`tar em đi`: `em` is the unit), before a next word ended by a file name character (`tee nhật.log`), after an English line (L10 would restore the word in `general` too) and with D29 off (the keep-Vietnamese list, L2, decides before L9 in every case); a word in sentence case keeps the keys when punctuation is glued to it (`Tar: thử`), when Return ends the line after it, or when a number, a path or a code character stands before it on the line (`1. Tar thử`, a numbered list item); for the same reason an English tech word that starts a Vietnamese line takes its Vietnamese display, as in `general` (`Host mowis chayj nhanh` gives `Hót mới chạy nhanh` by RV5; the escape `hosst` keeps `host`); a line that starts with a capital reads as a sentence, so an English sentence or a command typed that way in a code editor or a terminal shows the Vietnamese display of its first word (a README line `Tar archives are ...` shows `Tả archives are ...`, `Tee nhaatj.log` gives `Tê nhật.log`, an English commit subject `Tee stderr into log` typed in a terminal editor gives `Tê stderr into log`, and so after an English line or behind a quote, an indent or a list, heading or comment marker, `# Tar archives` gives `# Tả archives`; the escape `Tarr` keeps `Tar`, 4.7); a reset in the middle of a line makes the next word a line start (`ssh minh@host`, a click, then `tar thuwr` gives `tả thử`), and an RV5 revision cannot be undone with the restore key where the rules turn it off (the escape `tarr` keeps `tar`); a Vietnamese word glued to the previous one with no space (`việt/tả`) shows the keys as typed; `;` is prose punctuation, so a Vietnamese-looking name before it reaches the next command (`cd anh; tar xf a` gives `cd anh; tả xf a`, while `cd anh && tar` keeps `tar`); and an English tech word right after a Vietnamese word takes its Vietnamese display, as in `general` (`Cấu hình hót và port`; the escape `hosst` keeps `host`, 4.7, and the learned memory can learn the word). Since 18/11/2026 the same costs reach the code-only words whose keys are not English: `ef` on a line of its own keeps `ef`, and after an English word or a code character `chown` keeps its keys (`and chown`, `| chown`), as `tar` does. *(Amended after the product owner's report of 15/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, REG-35: the first version restored code-only words in `code` whatever the words around them, so a Vietnamese message typed in iTerm2, `Suwar looxi chinhs tar"`, committed `Sửa lỗi chính tar"`, twice in a row, against the promise that Vietnamese prompts typed in a terminal compose exactly as elsewhere. Amended again after the product owner's retest of 16/11/2026, REG-36: in iTerm2 a Vietnamese sentence that started with the word, `Tar thuwr cais nayf`, still gave `Tar thử cái này`, because at the start of a line nothing stands before the token and no rule looked at it again; RV5 applies the principle above one word late, as RV4 revises with the next word. Amended a third time on 16/11/2026 by the product owner, after seeing `Tar thử cái này` in iTerm2: a capital first letter at the start of a line is itself a sign of a Vietnamese sentence, since shell commands are typed in lowercase, so conditions (d) to (g) take such a word out of L9 at its own commit; the capitalized code-word list keeps configuration and protocol lines such as `Host github.com` out of that condition. Amended a fourth time after the review of the same day: the English run of the lines before no longer reaches a word that starts a sentence, because after an English command (`git status`, Return) the product owner's sentence still gave `Tar thử cái này` by L10; and the line start of (d), shared with RV5, admits spaces and the openers of prose before the first word, because `"Tar`, `- Tar`, `# Tar` and an indented `Tar` kept the keys with no rule left to revise them.)*
- **ENG-R851** The engine MUST NOT receive bundle identifiers, window titles or any other app information.

### 8.7 User lists and learning

- **ENG-R860** Resources include two user lists: keep-as-typed and keep-Vietnamese, keyed by lowercased raw keys. The host stores them locally and shows them in settings, where entries can be removed.
- **ENG-R861** When a token committed as user-restored or user-kept differs from what the rules alone would have decided, the output MUST carry a learning signal (`preferredRaw(raw)` or `preferredVietnamese(raw)`). One toggle gives one signal: when Backspace re-opens the token and it commits again with the same choice and the same raw keys, the output carries none (deleting letters and typing them again changes nothing); raw keys edited since make another word, whose choice was never reported, so its commit carries its own signal (`dduwowcj car`, toggle, space, two Backspaces, `s`, space gives a `preferredRaw` signal for `cas`); a new toggle is a new choice. The toggle that undoes a restore right after its commit (ENG-R706) carries the signal itself, the token being committed already, and its later re-commits carry none. The engine never stores it; the host decides whether to add it to a user list (ENG-R862).

- **ENG-R862** Host policy for learning (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md; storage and migration in docs/decisions/0320-per-app-learned-words.md): the host adds an entry once the same learning signal (same list, same raw keys) has been seen twice in the same app, and stores the learned entry **for that app** (bundle identifier); it applies only in that app. Entries the user types in settings stay global. Settings shows the app next to each learned entry and lets the user remove it or make it global. The engine still knows nothing about apps (ENG-R851): for the focused app the host passes the global entries plus that app's learned entries as the user lists of `Resources`. This policy applies only to words that are not on the bundled collision list (the ambiguity table and the collision supplement). For collision words the host feeds the learned memory of ENG-R863 instead, which is per user across all apps (decision of the product owner, 15/11/2026). Rationale: a user-list entry makes a collision word permanent in one direction and breaks `tricky á` next to `as hell`.
- **ENG-R863 Learned memory.** What is learned: only words on the bundled collision list, keyed by their lowercased raw keys, which are bundled vocabulary, never free text. Context class of the previous token of the run: sentence start (no previous token, after Return, Tab or a reset, or `.`, `!`, `?` or `:` among the boundary characters after it), otherwise its language (Vietnamese, English, neutral, ENG-R823). The host keeps two entries per word: one per class and one for any context, with corrections toward each side, silent acceptances of each side and the classes the corrections came from; it computes from them a vote per entry (`english`, `vietnamese`, `conflict`, or none): an entry votes for a side X when it holds at least one correction toward X, corrections(X) plus 0.25 x min(acceptances(X), 4) is at least 2, and that score is at least 3 x [corrections(Y) + 0.25 x min(acceptances(Y), 64)]; corrections on both sides and no winner is a conflict; the any-context entry votes only when its corrections came from at least two classes and none went to the other side. Lookup at commit: the class entry first; a class entry in conflict means the rules decide; otherwise the any-context entry. A revision (ENG-R828) may still revise a memory decision. The thresholds, decay, cap and storage are the host's (`02-platform.md`).
- **ENG-R864 Learning signals for collisions.** For a word of the collision list, `EngineOutput.collisionSignals` carries zero or more `CollisionSignal(word, context, side, strength)`. Strong: the restore toggle against the rules' own decision, on the active word or after Backspace re-opened it (the token commits as the user's choice and the output also carries the ENG-R861 signal), the toggle that undoes a revision (ENG-R829), and the toggle that undoes a context restore right after its commit (ENG-R706, for the Vietnamese side). For a re-opened token that a revision changed, the revision's side stands for the rules' decision while the token's raw keys are the ones the revision decided (`dduwowcj as hell `, six Backspaces, toggle, space gives `được á ` and a strong signal for the Vietnamese side); a letter deleted and typed again leaves them so, and raw keys edited otherwise make another word, which the rules alone decide. One toggle gives at most one strong signal, however often the token is re-committed with the same raw keys (ENG-R861). Weak: a token whose raw keys differ from its display, decided by L6, L7, L8, L9c, L10 or L11, that becomes final untouched: three later commits in the run, or Return or Tab; a revision, its undo, the undo of a context restore (ENG-R706), a Backspace that re-opens the token, a macro that folds it and a reset withdraw it; L9a and L9b never give one. The context is the class at the token's commit (ENG-R863). The engine stores nothing (ENG-R1202); the host does.
- **ENG-R865 Memory in resources.** `Resources.collisionMemory` is an immutable snapshot with `vote(word:context:) -> Language?`; the engine never mutates it. The host rebuilds the engine with a new snapshot at a hard boundary (ENG-R1211).
- **ENG-R866 Privacy of the memory.** `CollisionSignal.word` is the string of the bundled collision list equal to the token's lowercased raw keys, never other text; it exists so that the host can store and display the user's choice (same exception as `LearningSignal` in ENG-R1220).

### 8.8 Measurable targets

| ID | Target |
|---|---|
| ENG-R870 | Generated Vietnamese corpus (13.2): 100 % pass, including commit in Vietnamese context. The only allowed exclusions are raw strings that are `en` rows of the ambiguity table; they are listed by the test. Rows that the data build generates for rule L8 (raw keys an English word, display a valid syllable that is not attested) or for tech-always words count as such rows: they are marked `[generated:unattested]` or `[generated:tech-always]`, and the build fails when a row's reason no longer holds (policy accepted by the product owner on 13/11/2026). |
| ENG-R871 | English corpus (13.3), Telex defaults, English-run context: at least 99.5 % of words unchanged after commit; every failure listed in `known-exceptions.txt` with a reason. |
| ENG-R872 | Same corpus in Vietnamese context: at most 3 % of words changed (VERIFY after building the data), and 100 % of changed words are ambiguity rows with decision `vi` (reviewed or unreviewed). |
| ENG-R873 | Vietnamese prose corpus (13.4) typed by three simulated typists (canonical order, tone at end, free order): at least 99.95 % of tokens identical to the source; every difference attributable to an `en` row. |
| ENG-R874 | VNI: words without digits are never changed (100 %). |
| ENG-R875 | Zero crashes in fuzzing (13.6). |
| ENG-R876 | On the W11 collision corpus (13.11) the collision rules make no wrong revision and change no non-collision token (except a doubled word that L4 brings back to the word typed because the English-lean words or a phrase make the context English, ENG-R804: `The mess` and `Turn off`, two sentences, since 17/11/2026, and `Ê có sale off`, a third, since the phrase `sale off` of 18/11/2026); English-intent collisions at least 75 %, Vietnamese-intent at least 99 % with the tone typed at the end of the word (98.8 % with the tone typed after the vowel, 13.11); on the W11 adversarial sets no wrong revision; on the prose corpus (13.4) no token changes and no revision. |
| ENG-R877 | A memory fed only by silent acceptance never changes a decision; on held-out sentences the memory never lowers Vietnamese-intent accuracy by more than 1.5 points. |

---

## 9. Case, numbers, punctuation and boundaries

### 9.1 Case

- **ENG-R901** Each output letter takes the case of the key that produced the letter: `Vieetj` -> `Việt`, `VIEETJ` -> `VIỆT`, `DDaf` and `Ddaf` -> `Đà`, `dDaf` -> `đà`, `Aas` -> `Ấ`.
- **ENG-R902** The case of transform keys is ignored: `TieengS` -> `Tiếng`. Caps Lock is not special for keys that have a case: the host delivers the character it produced. The host also reports the Caps Lock state with every key (`KeyInput.capsLock`); only keys without a case use it (ENG-R906).
- **ENG-R903** A standalone `ư` takes the case of the `w` key (`W` -> `Ư`). An escape letter takes the case of the escaping key, except the escaped letter of a standalone `w` doubling (ENG-R804), which takes the place of the `ư` it removed: it is a capital when either `w` key is one, so `Ww`, `WW` and `wW` show `W` and `ww` shows `w` (`Wwade` shows `Wade`, `Wwebview` shows `Webview`, `TWwitter` shows `TWitter`). A horn or breve doubling (`Uww` -> `Uw`, `DOWwnload` -> `DOwnload`) and every other escape keep the case of the escaping key: there the first key gave no letter of its own. The raw keys stay as typed (ENG-R602), so the restore toggle shows `Wwade`. *(Amended by the product owner on 22/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 8, REG-41: until then the escaped letter of `Ww` was the lowercase `w` of the escaping key, so `Wwade` showed `wade` and rule L4 (b) committed it in lowercase.)*
- **ENG-R904** A token in which a lowercase letter is later followed by an uppercase letter and then by another lowercase letter (camel case: `iPhone`, `MacBook`, `useState`, `VnExpress`) MUST enter literal mode at the second lowercase letter if it is not already literal, and is restored at commit if it was transformed (rule L3b; `useState` shows `ueState` while typing and commits as `useState`). `tIẾNG` (inverted caps) stays Vietnamese. When the `w` doublings of the token are a habit (ENG-R804) and `R` is not English, the restore writes `R′`, the keys without them, every other key in its case: `WwordPress` shows and commits `WordPress` (ENG-R903), `wwebView` commits `webView`, `WweChat` commits `WeChat`; a horn or breve doubling keeps `R` (`dowwnLoad`), and so do `wwwRoot` and a capital `W` typed right after a lowercase `w`, which is no habit (`wWidth`, `dwWidth`, `swWidth`, `hwWallet` and `wWinMain` stay as typed; leaving the capital out would write `dwidth`, which the screen never showed). *(Added on 20/11/2026 with the product owner's decision on the doubled `w`, docs/decisions/0010-pa-decisions-2026-11-19.md item 7, REG-40: that item names rule L4, which a camel case token never reaches, so the brand and identifier spellings of the reported words, `WordPress`, `WeChat`, `WebView`, still committed both `w` through L3b.)*
- **ENG-R905** Case operations MUST NOT depend on the system locale.
- **ENG-R906** A letter produced by a Telex bracket key (ENG-R104), a key without case, is uppercase when Caps Lock was on for that key or when the token is an all-caps word, meaning that at least two other letters of the token were produced by keys with a case and all of them are uppercase: Caps Lock `[` -> `Ơ`, `TH[` -> `THƠ`, `TR]` -> `TRƯ`, `T[I` -> `TƠI`. Otherwise it is lowercase: `Th[` -> `Thơ`, `T[` -> `Tơ`, `[i` -> `ơi`. The case follows the current letters (6.1): `T[I` shows `Tơ` after the second key and `TƠI` after the third. The Caps Lock state of each bracket key is part of the token's input, so Backspace and replay keep it (ENG-R601). *(Decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md.)*

### 9.2 Boundaries

| Key | Telex | VNI | After commit |
|---|---|---|---|
| Space, any whitespace | boundary | boundary | keep history |
| `. , ; : ! ?` and every other ASCII punctuation or symbol character (apostrophe, quotes, hyphen, slash, backslash, `@ # ( ) { } < > _ = + * & % $ ^ ~`, backquote, vertical bar) | boundary | boundary | keep history |
| `[` `]` | boundary unless the bracket option is on | boundary | keep history |
| Digits `0`-`9` (main row) | boundary | transform or literal (4.2) | keep history |
| Keypad digits | boundary | boundary | keep history |
| Return (`"\n"`), Tab (`"\t"`) | hard boundary | hard boundary | commit, then clear history |
| Any letter outside `A-Z a-z` (for example `é`, `ß` from another layout, or a precomposed Vietnamese letter) | boundary | boundary | keep history |

- **ENG-R910** A boundary key commits the active token (section 8) and is then delivered (`passThrough`, or `thenPassThrough` after an edit). The engine records boundary characters in the history so that Backspace can walk back over them (section 10) and so that macro triggers containing punctuation or digits can be matched across them (section 11). Before committing, the engine checks the macro table (ENG-R1103).
- **ENG-R911** The apostrophe and hyphen are boundaries: `don't` composes as `don`, `'`, `t`; `M'Đrắk` as `M`, `'`, `Đrắk`.
- **ENG-R912** Return and Tab commit and then clear the history, because chat apps send on Return and Tab usually moves focus.

---

## 10. Context: Backspace across boundaries, cursor moves and resets

### 10.1 Re-opening the previous word

- **ENG-R1001** After a commit, the token (raw keys, display, flags) and the boundary characters typed after it stay in the history (default limit 16 tokens; older ones are dropped, never a crash).
- **ENG-R1002** Backspace with no active token removes the last recorded boundary character (`passThrough`). When the last boundary character before a token is removed, that token is re-opened as the active token with all its raw keys and flags, so further keys edit it: `chao` + space, Backspace, `f` -> `chào` (REG-07). This MUST work across `", "`, `". "` and double spaces.
- **ENG-R1003** Backspace continues into the re-opened token by the rules of 7.4, and past its start into the previous history entry.
- **ENG-R1004** If the history is empty, Backspace is `passThrough` and changes nothing.
- **ENG-R1005** A re-opened token that a commit rule restored (any `restored` decision of 8.1 except L1; an entry of the keep-as-typed list, L2, counts as a rule because it names a word, not this token) shows its raw keys, and keys typed into it are appended as typed (the toggle composes it, ENG-R704). After a restore wrote the keys without their `w` doublings (rule L4 or L3b, ENG-R804, ENG-R904, REG-40) the raw keys it shows are `R′`, the text the commit wrote, never `R` (the history keeps the raw keys as typed with the text `R′`, ENG-R1001), and a Backspace takes a `w` doubling it does not show together with the character before it, after which the token shows its raw keys (a token holds one `w` doubling at most, ENG-R804): `wwebview`, space, Backspace shows `webview`, and each further Backspace deletes one character of it; `answwer`, space, Backspace, toggle shows `ánwer`, the composed form. Every commit of the token sets or clears what it shows: a restore of a re-opened token that shows `R′` writes `R′` again (`answwer`, space, two Backspaces, space gives `answe `; `wwebview`, space, Backspace, `Kit`, space gives `webviewKit `), so a token never gains a `w` it does not show, and the next re-opening shows the text that commit wrote; a commit that writes the token's text unchanged keeps it showing `R′` (the typed word that the toggle took back from a correction, ENG-R1117: `wwindwos`, space, toggle, Backspace, space, Backspace shows `windwos`). When `R′` is also the composed form of the remaining keys the toggle on the re-opened token passes through (ENG-R701): `wwebview`, space, Backspace, toggle stays `webview`, and so does `Wwebview` with its capital (`Webview`), since the escaped letter of its standalone `w` doubling is a capital (ENG-R903, REG-41; until 22/11/2026 that toggle gave `webview`, the composed form, and a second toggle `Wwebview`). Its restore ends at the first Backspace after which the composed display of the remaining raw keys equals the text shown, that is when no remaining key transforms anything; from then on the token composes exactly like a token typed afresh with those keys (ENG-R1012). That Backspace changes nothing else on screen (ENG-R714). A writer who deletes back past the keys that made the word invalid or English and types again therefore gets Vietnamese: `tiesng`, space (restored, L5), five Backspaces, `eesn` shows `tiến`; `baas`, space, four Backspaces, `aasm` shows `bấm`; `huux`, space, two Backspaces, `w` shows `hưu`. Keys typed before such a Backspace stay as typed (`Safar`, space, Backspace, `i` gives `Safari`). A token the user restored with the toggle (ENG-R701, L1) stays literal for the rest of the token whatever is deleted; the toggle composes it again (E02b). At the boundary a re-opened token is decided by 8.1 on its raw keys at that moment, like any token, also while it still shows them as typed: `tieesngg`, space, two Backspaces, space gives `tiếng `; `boss`, space, two Backspaces, space gives `bó `. Known cost: `text`, space, two Backspaces, space gives `tẽ ` (`tex` is not English).
  *Rationale: the field shows the keys as typed both for a literal token and for a restored one, so the writer cannot tell them apart, and literal mode already ends when Backspace removes its cause (ENG-R421: `chuognw`, space, four Backspaces, `ngw` gives `chương`). The commit judged the word that was typed; once Backspace has removed every key whose effect the restore undid, that judgement describes nothing on screen. Reported by the product owner on 15/11/2026 from a dev trace (REG-33): the first version kept the restore until the token ended, so `tiesng`, space, five Backspaces, `eesn` showed `tieesn`.*

### 10.2 Resets (host-sent)

- **ENG-R1010** The host MUST send `reset(reason)` for: cursor movement keys (arrows, Home, End, Page Up/Down, with or without modifiers), mouse clicks in the text area, focus change, app switch, input source change, Secure Event Input turning on or off, the event tap being re-enabled after a timeout, any shortcut with Command or Control (including Command+Backspace and Control+Backspace), Option+Backspace (the app deletes a word), Forward Delete with or without modifiers, mode toggle (Vietnamese/English), configuration change, input that reached the app without the host seeing it (a keyUp without its keyDown, `02-platform.md` PLT-R397A; reason `unseenInput`), and any case where the host cannot vouch for the text before the cursor. Only a plain or Shift Backspace reaches the engine as `backspace` (`02-platform.md` PLT-R352).
- **ENG-R1011** On reset the engine MUST clear the active token and the history and return no edit. Text on screen stays as it is.
  *Rationale: the incumbent did not reset after the tap was re-enabled and then sent wrong deletions.*
- **ENG-R1012** After a reset, the next key starts a fresh token; it is treated exactly like any other first key (REG-18, REG-22).

---

## 11. Macros (text expansion)

Macros are a v1 feature. `03-product.md` section 8 owns the editor, storage, import, the per-app switch and the "not in English mode" rule; the engine owns matching and expansion so that the edit is exact and the trigger is restorable.

- **ENG-R1101** A macro table maps a **trigger** to an **expansion**. Trigger: 1 to 32 characters of printable ASCII without whitespace (letters, digits and punctuation such as `@`, `;`, `.`, `~`), compared case-insensitively against the keys as typed. Vietnamese letters are not allowed in triggers because matching is on raw keys (`dc`, not `đc`). Expansion: NFC text of at most 4,000 characters, newlines allowed.
- **ENG-R1102 Matching window.** The engine keeps the **span**: the raw characters typed since the last whitespace, Return, Tab or reset, including boundary characters such as punctuation and digits that were passed through (so `@@`, `ad.`, `k1` are matchable), capped at 32 characters (a longer span cannot match and is not looked up). Because triggers are matched on raw keys, composition state, literal mode and escapes do not matter (this resolves the former Q6).
- **ENG-R1103 Expansion.** On a boundary key, before rule L0 of section 8.1, if the lowercased span equals a trigger, the engine MUST replace the span's display (the committed tokens and boundary characters it consists of, all engine-produced or passed through, so ENG-R630 holds) with the expansion and deliver the boundary key (`thenPassThrough`). The terminator is therefore whitespace, Return, Tab, or a punctuation key, whichever comes first after a complete trigger. A trigger that equals another trigger plus trailing punctuation can never fire (the shorter one fires first); the host's editor MUST reject such a pair with an explanation. A trailing main-row digit counts like punctuation in this check (`k` and `k1`: in Telex the digit is a boundary, so `k` fires first); the engine's table validation and the host's editor apply the same check (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md; upgrade path for pairs saved by earlier builds in docs/decisions/0321-trailing-digit-macro-shadowing.md). Case: trigger typed in all capitals -> expansion uppercased; first letter capital -> first letter of the expansion capitalised; otherwise as stored. Adaptive casing MAY be turned off per entry (`adaptCase: false`), and is skipped when the trigger contains no letters.
- **ENG-R1104** An expansion is recorded in the history as one token with raw keys equal to the span as typed and display equal to the expansion, flagged literal. Backspace into it deletes one character at a time (`passThrough`); the restore toggle right after an expansion (after one Backspace re-opens it) brings back the span as typed, and `CommitDecision.macro` names the decision.
- **ENG-R1105** Macro matching MUST be a hash lookup on the lowercased span: cost independent of the table size. Tables of 10,000 entries MUST stay within ENG-R1230.
- **ENG-R1106** Macro contents are user data: never logged, never in diagnostics, synced only if the user opts in to sync (`02-platform.md` PLT-R1011).
- **ENG-R1107** Whether macros are active in a given field is decided by the host (English mode, per-app rule `features.macros`, `03-product.md` D10); the host passes an empty table in that case. Changing the table is a configuration change (ENG-R1211).

Examples (table: `vn` -> `Việt Nam`, `@@` -> `kal@example.com`, `dc` -> `được`): `vn` + space -> `Việt Nam `; `Vn` + space -> `Việt Nam `; `VN` + space -> `VIỆT NAM `; `vn.` -> `Việt Nam.`; `@@` + Return -> `kal@example.com` + Return; `dc` + space -> `được ` (the span `dc` matches before any restore decision; without the macro, `đc` would be kept by L3); `vnd` + space -> no macro (span `vnd`).

---

## 11A. Typo and spelling correction (1.1.0)

Planned for 1.1.0 under PRD-R4A of `03-product.md` (the product owner's decision of 16/11/2026: after 1.0, not part of it; on by default by the decision of 18/11/2026, which the release track records in `docs/decisions/0009-pa-decisions-2026-11-18.md`). At the commit of a word the engine replaces one clearly mistyped word with the only word it can be, offline, from the bundled data, with no suggestion list; ENG-R122 is amended accordingly. The product side (the setting D30, the never-correct list and their copy) is `03-product.md` PRD-R80 and PRD-R81. Requirements ENG-R1110 to ENG-R1125, tests ENG-T50 to ENG-T57, worked examples 13.12 (rows S01 to S84). Terms used here: the **typed word** is the keys a restore puts back (ENG-R803), lowercased: the token's raw keys `R`, or `R′` when rule L4 restores the token without its `w` doublings (ENG-R804), so the correction reads what the screen shows (`wwindwos` shows `windwos`, L4 restores `windwos` and one transposition gives `windows`; read on `R`, no single edit of `wwindwos` gives a word; a token that (d) keeps as a deliberate form is no candidate, ENG-R1110 (b), so a one-syllable typo typed with the habit stays as shown: `wwhcih` gives `whcih`, while `whcih` gives `which`) *(amended by the product owner on 20/11/2026, docs/decisions/0010-pa-decisions-2026-11-19.md item 7, REG-40; until then the typed word was `R` in every case)*; the **correction lexicon** is the English lexicon of 8.2 plus the letter-only entries of the tech-always list; the **guard list** is the list of rarer English words and proper names of ENG-R1120; the **never-correct list** is the user list of ENG-R1118. The correction never changes a Vietnamese word (ENG-R1110 (d)), and it leaves a mistyped word alone when one key would make it Vietnamese (ENG-R1125: `ddi pahir` stays `đi pahir`, it does not become `đi pair`), because a word that could be a Vietnamese typo is not a word of which "exactly one word fits". It corrects no Vietnamese typo either: a mistyped Vietnamese syllable is usually one key away from several valid ones, so Vietnamese typo patterns are a later phase with their own rule (ENG-R1123).

### 11A.1 Where the correction sits and which tokens are candidates

- **ENG-R1110 Candidate.** At a commit, after the macro check (ENG-R1103) and after the decision of 8.1 has been taken with its reason code, and before the edit of ENG-R803 is formed, the engine decides whether the token is corrected. The decision reads the token alone (its raw keys, its display `C`, its flags, the 8.1 decision, the key that commits it, the boundary characters between the previous token and the token, and whether the token starts a sentence, the class of ENG-R863) and the resources; it never waits for the words after the token. A token is a **candidate** when all of the following hold; a token that is not a candidate commits exactly as in 1.0:
  (a) `typoCorrection` is on and the app context is `general` (ENG-R1119);
  (b) the 8.1 decision would leave the typed word on screen: rule L0 (`C` equals `R`), or a `restored` decision of any rule other than L1 and L2; or `C` is kept by L6, the onset of `C` (3.13) is one of the clusters `bl br dr đr gl gr kl kr pl pr` (the Tier B onsets of place names, 3.3), the typed word is all lowercase and is not English: the product owner's case study `gramar`, which shows `grẩm` and which L6 keeps because `gramar` is not English (PRD-R4A). The cluster case needs a transformed display: L0 comes before L6, so a cluster token shown exactly as typed (`glong`, `Glong`, `krong`) is decided by L0 and is then a candidate only if (d) allows it, which it does not, being Tier B and an unmarked shape. A token kept by L1 (the user's toggle), L2 (a user list), L3 (an abbreviation), L4 (a deliberate escaped form), L7 to L11 or the memory (L9c), a token revised by ENG-R828, a macro expansion (ENG-R1104) and a re-opened token that was corrected or restored before (ENG-R1117) are never candidates;
  (c) the typed word is not a word of any list: not in the English lexicon, the tech-always list or the code-only list (`chown` and `mkdir` are words in prose too), not in the guard list (ENG-R1120), not in the user's keep-as-typed or keep-Vietnamese lists (ENG-R860, with the per-app entries the host merges in, ENG-R862), not in the never-correct list (ENG-R1118) and not on the collision list (8.1: the ambiguity table and the collision supplement). The collision list holds every word the learned memory can hold (ENG-R863), so a word the memory holds is never a candidate (PRD-R4A); the check is explicit because the collision supplement is by construction outside the English lexicon (8.2);
  (d) the typed word is not Vietnamese: `C` is neither Tier A nor Tier B (3.12), except in the cluster case of (b), and the typed word is not an **unmarked shape**, the letters of a Tier A or Tier B syllable with its marks and stroke removed (ENG-R1120: `truong`, `nguoi`, `khong`, `thuong`, as chat is often typed without marks; `truing` is one letter away from `truong`), nor one edit away from Vietnamese (ENG-R1125);
  (e) the conditions of ENG-R1111 (letters, length, case) and ENG-R1112 (context) hold.
  The engine then applies the edit model of ENG-R1113 and corrects the token only when exactly one word fits (ENG-R1114).
- **ENG-R1111 Letters, length and case.** The typed word consists of ASCII letters only (a VNI token with a digit, a Telex token with a bracket letter and a token with any other character are never candidates; in Telex a main-row digit is a boundary, 9.2, so `androd1` commits `androd` at the digit and ENG-R1112 leaves it alone) and has 5 to 24 letters (PRD-R4A: at least five; the cap bounds the work of ENG-R1122). Its case decides where it may be corrected: a word in lowercase anywhere; a word in sentence case (the first letter uppercase, every other letter lowercase, ENG-R850 (e)) only where it starts a sentence (no previous token in the history, or `.`, `!`, `?` or `:` among the boundary characters after the previous token: the sentence-start class of ENG-R863), because inside a sentence a capital is a name (`Kbang`, `Glong`, `Biden`), and the correction keeps the case (`Androdi` gives `Android`); a word in any other case (all capitals `ANDRODI`, mixed `AndroDi`, camel case) never. A word whose last letter is repeated three or more times in a row (`stilll`, `coolll`, `smalll`) is a chat elongation, not a typo, and is never a candidate, although deleting one letter would give a word (`still`); in Telex an elongated tone key is an escape and L4 decides the token first (`yesss` commits `yess`, ENG-R804 (d)).
- **ENG-R1112 Context.** No correction is made: in the `code` app context (ENG-R850: terminals, IDEs and code editors; whatever the words around the token, unlike rule L9); when the key that commits the token is not whitespace, Return, Tab or one of the closers of prose `. , ; : ! ? ) ] } "`, all ASCII so that the undo of ENG-R1117 always applies (a digit, the non-ASCII `” …`, an apostrophe or closing single quote `' ’` (`weren't` commits `weren`, one letter from `wren`), `/`, `@`, `\`, `-`, `_`, `#`, `~`, the backquote, `|`, `&`, `$`, `=`, `+`, `*`, `%`, `^`, `<`, `>`, `(`, `[`, `{` and every other character leave the token as decided: the user is typing an identifier, a path, a link or a contraction); and when the character right before the token's first letter is neither a space (U+0020 or U+00A0) nor an opening bracket or quote `( [ { " “ ‘ '`, unless nothing but spaces and tabs stands between the start of its line (no previous token in the history, or the last boundary was Return) and the token, so that the first word of a field, of a line or of an indented line is a candidate: the openers of ENG-R850 (d) count only when a space follows them (`- androdi`, `> androdi`, `# androdi`, which pass by the space), and a token glued to `#`, `/`, `@` or `-` is glued at a line start as anywhere else (`#androdi` starting a post is a tag). A token glued to `.`, `/`, `@`, `\`, `-`, `_`, `#`, `:`, `~` or a digit is part of a link, an e-mail address, a path, a tag, a mention or a compound (`www.exapmle.com`, `kal@exapmle.com`, `/opt/locla`, `#androdi`, `well-knwon`). Known cost: a word committed by `.` is corrected before the engine can know that a domain follows (`googel.com` would give `google.com`).

### 11A.2 Edit model and the one-word rule

- **ENG-R1113 Edit model.** The correction considers the words at distance one from the typed word under these edits, applied to the letters of the typed word (keys, never the display: `gramar`, not `grẩm`):
  (1) **transposition** of two neighbouring letters (`androdi` -> `android`, `recieve` -> `receive`, `whcih` -> `which`);
  (2) **deletion** of one letter (`untill` -> `until`, `arguement` -> `argument`, VNI `messsage` -> `message`; in Telex the `ss` of `messsage` is an escape and L4 (b) keeps `message` before any correction), except the first letter unless it equals the second (`aabout` -> `about`, but never `kbang` -> `bang` or `xcode` -> `code`: names of ethnic-minority places and of tools begin with consonant pairs) and except the last letter unless it equals the one before it (`helpp` -> `help`, `committ` -> `commit`, but never `messi` -> `mess` or `biden` -> `bide`);
  (3) **insertion** of one letter (`gramar` -> `grammar`, `adress` -> `address`, `langage` -> `language`, `libary` -> `library`), except after the last letter unless it repeats it (`pajama` never becomes `pajamas`: plurals and inflections the lexicon lacks are words, not typos);
  (4) **substitution** of one letter by a neighbouring key (`servet` -> `server`, `hwllo` -> `hello`), the neighbours given by the table below, except a last letter `r` after `e` replaced by `d` (`leecher` and `absorber` would become `leeched` and `absorbed`: the lexicon lists participles more often than the nouns in `-er` derived from the same verbs; `leecher` is the word of REG-37).
  Neighbours (the standard QWERTY layout; bundled data, ENG-R1120; symmetric, and the build fails otherwise): `q: w a` · `w: q e a s` · `e: w r s d` · `r: e t d f` · `t: r y f g` · `y: t u g h` · `u: y i h j` · `i: u o j k` · `o: i p k l` · `p: o l` · `a: q w s z` · `s: w e a d z x` · `d: e r s f x c` · `f: r t d g c v` · `g: t y f h v b` · `h: y u g j b n` · `j: u i h k n m` · `k: i o j l m` · `l: o p k` · `z: a s x` · `x: s d z c` · `c: d f x v` · `v: f g c b` · `b: g h v n` · `n: h j b m` · `m: j k n`. Layout assumption: the engine never sees key codes (section 2), so the table is a stated assumption, QWERTY, the layout of the keyboards Apple sells in Vietnam and the one the ABC and U.S. input sources assume; on QWERTZ, AZERTY or Dvorak the substitution edit finds fewer typos and the other three edits are unaffected. A later version MAY let the host pass the table of the active layout.
- **ENG-R1114 One word.** The words that fit are the distinct words of the correction lexicon (the English lexicon of 8.2 and the letter-only entries of the tech-always list; never the code-only list, the guard list or any Vietnamese data) of at least four letters that one edit of ENG-R1113 reaches. The token is corrected only when exactly one word fits (PRD-R4A); two or more (`thier`: `their`, `tier`, `thief`; `wierd`: `weird`, `wired`; `pleasee`: `please`, `pleases`, `pleased`) or none (`grammer`: `e` and `a` are not neighbours) leave it as decided. There is no frequency or size-level tie-break: the lexicon carries membership only (8.2), and a tie-break would turn "the one word it can be" into a guess. A word that several edits reach counts once (`gramar` -> `grammar` by inserting `m` at either position). Vietnamese counts as a fit too: a typed word one edit from Vietnamese is never corrected (ENG-R1125).
- **ENG-R1125 Vietnamese within one edit.** A candidate is not corrected when any single edit of its typed word reaches Vietnamese: a transposition of two neighbouring letters, a deletion of any letter, an insertion of any letter at any place or a substitution by a neighbouring key of the table of ENG-R1113, without the position rules of ENG-R1113 (they protect English words, not Vietnamese ones), giving either (1) a **Vietnamese keying**, the Telex keys of a Tier A syllable (3.12) with a tone it allows, written in the usual order: the onset, the vowels and the coda letter by letter, each marked letter as its two keys (`aa aw ee oo ow uw dd`, also `uow` for `ươ` and `w` for a leading `ư` after a consonant other than `q`), and the tone key (`s f r x j`, none for the level tone) last or right before the coda (`phair`, `phis`, `chinhs`, `thieeus`, `hoanf`); or (2) an unmarked shape of ENG-R1110 (d) (`thach`, `chip`). Such a word can be a Vietnamese word with one key wrong as well as an English one, so the English word is not the only word it can be (PRD-R4A, "Vietnamese first"): `ddi pahir` (`phải` with `h` and `a` swapped) stays `đi pahir`, and `pehis`, `hoand`, `chihns` and `htach` stay as typed instead of becoming `penis`, `hand`, `chins` and `hatch`. The check is the same in Telex and VNI (a VNI word typed with its digits is not a candidate, ENG-R1111, and one typed without them is within one edit of its unmarked shape). The keyings are the usual order only, not every order Telex accepts: `gamar` composes `gẩm`, yet `gramar` is one deletion from it and must still give `grammar`. Measured on 18/11/2026 with a model of these rules: of 3,371 one-key Telex typos of the words of the prose corpus (13.4), 133 had exactly one English fit without this rule and 10 with it, nine of them typos of English words of the corpus (`internte`, `pagge`) and one a typo of the Tier B loanword `blốc` (`bloofs` -> `bloods`); of the injected English typos of ENG-T52 it leaves 0.2 to 1.5 points fewer corrected (ENG-R1124).

### 11A.3 The edit, the history and the words around

- **ENG-R1115 The edit.** The commit's edit replaces the token's display (what the 8.1 decision would have shown: the keys as typed after L0, the display `C` that a restore would have replaced, `grẩm` in the cluster case) with the correction in the case of ENG-R1111, followed by the key that commits the token (`thenPassThrough`), in one `TextEdit`, never two (ENG-R803). `EngineOutput.decision` is `corrected(rule)`, where `rule` names the 8.1 rule that would have decided the token (`unchanged`, `invalid`, `escape`, `extendedSpelling`), so diagnostics can say "corrected; the word was not a syllable" without storing text (ENG-R801). The history (ENG-R1001) keeps the token with the keys of its typed word as typed (`R`, or `R′` after rule L4, REG-40), the correction as its display and the flag **corrected**; it is literal, as a macro expansion is (ENG-R1104).
- **ENG-R1116 Language, revisions and boundaries.** A corrected token is `en` for the English run (ENG-R823): the engine put an English word there. It is not a collision word, so it gives no collision signal and reads no memory (ENG-R863, ENG-R864). A commit never both revises and corrects: the evidence rules of ENG-R828 read the committing token's own decision and raw keys, which a candidate never satisfies (its raw keys are neither English nor a Vietnamese syllable), and a token that ENG-R828 revises is a collision word, never a candidate. The correction is decided at every key that commits (P0-3, 13.9.1), Return and Tab included, with the same result, except that ENG-R1112 reads the key itself; so `androdi` followed by Return sends `android` in a chat app, as a restore would.
- **ENG-R1117 Undo and re-opening.** A `restoreToggle` that immediately follows a commit which corrected the token MUST answer with an edit that replaces the correction with the keys of the typed word as typed (the raw keys, or `R′` after rule L4: `wwindwos`, space, toggle gives `windwos `; the boundary character unchanged; the shape of the revision undo of ENG-R829 and PLT-R353; every key that can commit a correction is ASCII, ENG-R1112, so the pass-through of ENG-R829 after a non-ASCII boundary never applies to it), mark the token user-restored (L1 if it is re-opened) and carry `LearningSignal.neverCorrect(raw)` (ENG-R1118); the next toggle passes through (ENG-R702). After Return or Tab the history is cleared and the toggle passes through (ENG-R829): a correction at Return cannot be undone with the key. Backspace after the commit removes the boundary character and re-opens the corrected token (ENG-R1002), which shows the correction and is literal: Backspace deletes one character at a time (`passThrough`, ENG-R714), keys typed into it are appended as typed, and the toggle right after the re-opening brings back the keys of the typed word as typed, marks the token user-restored and carries the same signal (as ENG-R1104 does for a macro). A re-opened corrected token is never corrected again: its next commit changes nothing on screen and reports `corrected` again, or `kept(userChoice)` once the toggle restored it, and the token keeps the keys of its typed word, so the next re-opening shows the same text and its toggle answers as before (`R′` included, ENG-R1005).
- **ENG-R1118 Learning and the never-correct list.** `LearningSignal.neverCorrect(raw)` carries the typed word (lowercased ASCII letters) of a correction the user undid with the toggle. The host adds it to the **never-correct list** at once: one signal is enough, because the user acted against a change they saw (unlike ENG-R862, which waits for two signals). The list is per user and applies in every app (like the memory of ENG-R863, not per app like ENG-R862); the host stores it next to the keep lists and shows it with them in settings, where entries can be added (lowercased, letters only; anything else is refused with an explanation) and removed, and exports and imports it with the keep lists (`03-product.md` PRD-R81). The host passes it to the engine as `Resources.userNeverCorrect` (12.2); a word on it is never a candidate (ENG-R1110 (c)). The list is user data: never logged, never in diagnostics except as a count (as macros, ENG-R1106). The engine stores nothing (ENG-R1202).
- **ENG-R1119 Configuration.** `EngineConfiguration.typoCorrection` (default true) enables this section. The host passes the user's D30 switch ANDed with D4 (`autoRestore`: with English restore off the English data is not consulted, ENG-R802, and no correction is made), with the rule's `features.englishRestore`, the existing per-app switch, and with the rule's `features.restoreHotkey` (and the user's D8): a correction is made only where the restore key can undo it, for the reason PLT-R357 gives for the revisions, so the launchers whose rule turns the restore key off (Spotlight and the overlay panels of `compat/rules.json`, where Escape closes the panel) and every app where D8 is off get no correction. No new rule flag is needed: the `code` context already turns the correction off (ENG-R1112), the restore key decides the rest, and the edit is of the same kind as a restore (ENG-R803), which every strategy applies. With `typoCorrection` off no output carries `corrected(...)` or `LearningSignal.neverCorrect`, a toggle after a commit behaves as ENG-R703, ENG-R706 and ENG-R829 say, and every corpus and worked example outside 13.12 gives the result it gives with the section absent (ENG-T54 checks this, as ENG-R829 does for `lookaheadRevision`). Changing it is a configuration change (ENG-R1211).

### 11A.4 Data, privacy, performance, later phases

- **ENG-R1120 Data.** Five resources, all built by `lexicon-builder` from pinned inputs with recorded checksums (ENG-R810), none embedded in the core (ENG-R812): (1) the correction lexicon needs no new file (ENG-R1114); (2) the **guard list**: the SCOWL "words" lists of sizes 40 to 70 and the SCOWL "proper-names" lists of sizes 10 to 70 (the American, British, British-z and English components of the pinned archive, `data/inputs/english/SOURCES.tsv`), minus the correction lexicon, under the same notice as the lexicon (ENG-R811); shipped as a membership structure that MAY answer yes for a word it does not hold (a false positive only suppresses a correction; at most 0.5 % on random letter strings) and takes at most 512 KB resident; (3) the **keyboard neighbours** table of ENG-R1113, 26 entries, reviewed with the lists; the build fails when it is not symmetric or does not cover every letter; (4) the **unmarked shapes** of ENG-R1110 (d), generated from the tier tables like the viability structure (ENG-R346, never hand-written): every Tier A and Tier B syllable, tone ignored, with `ă â` -> `a`, `ê` -> `e`, `ô ơ` -> `o`, `ư` -> `u`, `đ` -> `d`; (5) the **Vietnamese keyings** of ENG-R1125, generated from the same tables (27,277 key strings as built on 19/11/2026; the 27,367 measured on 18/11/2026 came from a model that also keyed the standalone `w` after no onset and predated the pairs `giếc` and `Thy`, `docs/decisions/0203-correction-data.md` section 4), or computed on the fly by a parser of the usual order that reads an edited string back into onset, vowels, coda and tone; either way ENG-T56 compares the result with an independent computation. Together they add at most 1 MB of resident memory; ENG-R1231 holds for the whole of the resources.
- **ENG-R1121 Privacy.** Nothing in this section logs, prints, persists or transmits keys or text (ENG-R1220). `corrected(rule)` carries no text. `neverCorrect(raw)` carries the typed word only so that the host can add it to a list the user can see, the exception ENG-R1220 already makes for `LearningSignal`. Diagnostics MAY count corrections and undos; they never record the words.
- **ENG-R1122 Performance.** Candidate generation and lookups are hash or trie lookups on preallocated tables (ENG-R1232), proportional to the token's length (at most 24 letters, ENG-R1111), never to the size of the lexicon or the guard list. A commit that evaluates a candidate MUST complete within 50 µs at p99 and 200 µs in the worst case on the baseline machine of ENG-R1230, and the percentiles of ENG-R1230 on the ENG-T40 benchmark MUST NOT move beyond the benchmark's noise band (candidates are rare in the corpora). The added data loads within the 50 ms of ENG-R1231.
- **ENG-R1123 Vietnamese typo patterns (later phase).** 1.1.0 corrects no Vietnamese. A later version MAY add a Vietnamese pattern only when all of these hold: (a) it is written down as a bundled list of `typed -> corrected` pairs or as one explicit rule; (b) no typed form is a Tier A or Tier B syllable, an unmarked shape or an English word; (c) each typed form has exactly one corrected form; (d) the pattern makes zero corrections on the generated corpus (13.2), the prose corpus (13.4, with and without marks) and the W11 corpus (13.11); (e) the product owner reviewed the list. A pattern whose typed form is close to several valid syllables is never added, whatever its frequency (PRD-R4A).
- **ENG-R1124 Measurable targets.**

| Target | Value |
|---|---|
| Vietnamese prose corpus (13.4), three typists, both methods, both tone styles | zero corrections |
| Prose corpus with its marks removed, every token typed as plain letters (unmarked Vietnamese) | zero corrections (without the shape rule of ENG-R1110 (d) and ENG-R1125, 20 distinct tokens in 6,581 places of the corpus would change: `truong`, `thuong`, `phong`, `duong`, `huong`) |
| One-key typos of Vietnamese words (ENG-T57): every distinct word of the prose corpus (13.4), typed in Telex with the tone key last and, as a second run, typed as plain letters, receives one random edit of each kind (transposition, omission, insertion, neighbouring key; seed recorded) | a typo of a Vietnamese word corrected to an English word: at most 0.1 % of the typos with five or more keys, the list printed (a model of these rules, 18/11/2026: 1 of 3,371 Telex typos, `bloofs` -> `bloods` from the Tier B loanword `blốc`; none of the 579 plain-letter typos that are neither words nor shapes; without ENG-R1125, 133 and 53) |
| Generated corpus (13.2); the W11 corpus and its three sets (13.11) | zero corrections |
| English lexicon, tech-always list, code-only list and guard list, each word typed in Telex and VNI, lowercase after a Vietnamese word and in sentence case at the start of the input | zero corrections |
| Injected typos (ENG-T52): words of the lexicon with one edit, 6,000 words per kind, the seed recorded | corrected to the source: transposition at least 80 %, doubled letter at least 90 %, neighbouring key at least 80 %, omitted letter at least 50 %, added letter at least 70 %; corrected to another word: at most 1.5 % per kind (a model of these rules on the bundled lexicon with ENG-R1125, seed 18112026, 18/11/2026: 85.7, 95.2, 86.7, 57.5 and 75.8 %; 0, 0, 0.05, 1.32 and 1.20 %) |
| Rare words (ENG-T53): the words of `/usr/share/dict/words` (web2, public domain) outside the lexicon and the guard list | at most 3.5 % corrected, the list printed (3.42 % measured on 18/11/2026 without the guard list) |
| Fuzz (ENG-T54) | zero crashes, every invariant |
| A commit that evaluates a candidate (ENG-T55) | ENG-R1122 |

### 11A.5 Acceptance tests

- **ENG-T50 Worked examples.** The rows of 13.12 replayed with the bundled data (8.2) and the fixture entries the table names, in Telex (and VNI where a row says so), asserting the text after the committing key, the decision, the learning signal and the edits of the undo rows.
- **ENG-T51 Zero-change corpora.** With `typoCorrection` on: the prose corpus (13.4) typed by the three typists in Telex and VNI, both tone styles; the prose corpus with its marks removed, every token typed as plain letters, after a space and at the start of a line; the generated corpus (13.2); the W11 corpus and its three sets (13.11); and every word of the English lexicon, the tech-always and code-only lists and the guard list, typed in Telex and VNI, lowercase after a Vietnamese word and in sentence case at the start of the input. No token is corrected; the test prints every token that was.
- **ENG-T52 Injected typos.** For each kind of edit (transposition, deletion, insertion of a random letter, doubling of a letter, neighbouring key), 6,000 words of at least five letters drawn from the lexicon with a recorded seed receive one such edit and are typed after a space; the test counts the words corrected to the source, corrected to another word and left untouched, and asserts ENG-R1124. The measured figures are recorded with the seed in the engine's traceability.
- **ENG-T53 Rare words.** Every word of `/usr/share/dict/words` with five or more ASCII letters that is in neither the lexicon nor the guard list, typed lowercase after a space: at most 3.5 % are corrected; the test prints the list. The file is read from the machine when present and the test is skipped otherwise, so the gate runs on macOS.
- **ENG-T54 Fuzz invariants.** The fuzz run of 13.6 also runs with `typoCorrection` on, the bundled data and a random never-correct list: ENG-T30, ENG-T31, ENG-T33, ENG-T34, ENG-T37 and ENG-T38 unchanged; ENG-T32 extended: a toggle right after a corrected commit, or right after Backspace re-opened a corrected token, gives exactly the keys of the typed word as typed; ENG-T35 extended: in VNI, every inserted string that is not the raw keys or a composition of typed letters is a word of the correction lexicon; and further: no correction in `code`; with the switch off, no output carries `corrected(...)` or `neverCorrect` and every toggle after a commit answers as ENG-R703, ENG-R706 and ENG-R829 say (the 1.0 behaviour itself is held by the existing corpora and worked examples, run with the switch off); none of a token on any list; none of a typed word within one edit of a Vietnamese keying or an unmarked shape (ENG-R1125); none that deletes more than the active token's display; never two edits in one event; never a correction together with a revision; and every `neverCorrect` signal names the typed word of the token it came from.
- **ENG-T55 Performance.** A benchmark types 10,000 candidate tokens (typos of lexicon words, 5 to 24 letters) after a space and asserts ENG-R1122; the ENG-T40 percentiles with the switch on and off differ by less than the benchmark's noise band (ENG-R1233).
- **ENG-T56 Data.** The neighbours table is symmetric and covers the 26 letters; the guard list holds no word of the correction lexicon and answers yes for at most 0.5 % of 100,000 random letter strings; the unmarked shapes and the Vietnamese keyings equal an independent computation from the oracle's tables (ENG-T01); every bundled file of ENG-R1120 is byte-reproducible (ENG-R810).
- **ENG-T57 Vietnamese typos.** The two runs of the ENG-R1124 row "One-key typos of Vietnamese words", typed after a Vietnamese word with `typoCorrection` on: the test counts the typos of Vietnamese words (words that are Tier A or Tier B) that are corrected and asserts the target; a typo of an English word of the corpus (`internte`) may be corrected and is not counted. The measured figures are recorded with the seed in the engine's traceability.

---

## 12. Engine API (Swift)

### 12.1 Package layout

| Target | Kind | Contents | Dependencies |
|---|---|---|---|
| `VietnameseEngine` | library | Core: orthography, composition, commit rules. | Swift standard library only (no Foundation, no AppKit, no UIKit). |
| `VietnameseEngineData` | library | Bundled resources (8.2) and their notices, `Resources.bundled()`. | `VietnameseEngine`, Foundation (resource loading). |
| `VietnameseEngineTesting` | library (tests only) | Independent oracle, corpus generators, simulated text field, fuzz drivers. | `VietnameseEngine`. |
| `lexicon-builder` | executable | Builds resource files from pinned inputs (ENG-R810). | Foundation. |

- **ENG-R1201** Swift 6 language mode with complete strict concurrency checking, using the latest stable toolchain at implementation time (Swift 6.4.2 with Xcode 27.2, `docs/decisions/0500-ci-runners-and-toolchain-pins.md`). Package platforms: `.macOS(.v12)`, the app's own minimum, so that the engine never constrains it (PLT-R106, `docs/decisions/0315-minimum-macos-12.md`). The core SHOULD also build on Linux so CI can fuzz cheaply. *(Amendment of 2026-11-18: the floor read `.macOS(.v13)`, written before the app's minimum moved to macOS 12; the package has declared `.macOS(.v12)` since ADR 0315.)*
- **ENG-R1202** No global or static mutable state anywhere in the package. No singletons.
- **ENG-R1203** All public types MUST be `Sendable`. Value types MUST be `Hashable` where listed. Large immutable data (lexicons) MAY sit behind a final class with only `let` properties.

### 12.2 Public API (proposed)

```swift
public enum InputMethod: Sendable, Hashable { case telex(TelexOptions), vni }

public struct TelexOptions: Sendable, Hashable {
    public var standaloneW: Bool      // default true
    public var bracketKeys: Bool      // default false
    public init(standaloneW: Bool = true, bracketKeys: Bool = false)
}

public enum ToneStyle: Sendable, Hashable { case traditional, modern }
public enum AppContext: Sendable, Hashable { case general, code }

public struct EngineConfiguration: Sendable, Hashable {
    public var inputMethod: InputMethod   // default .telex(TelexOptions())
    public var toneStyle: ToneStyle       // default .traditional
    public var autoRestore: Bool          // default true
    public var appContext: AppContext     // default .general
    public var historyLimit: Int          // default 16 tokens, minimum 1
    public var lookaheadRevision: Bool    // default true: L9a, L9b, run exemption, lean window, RV1-RV4 (ENG-R829)
    public var lineStartRevision: Bool    // default true: RV5 in the code context, the user's D29 (ENG-R829)
    public var typoCorrection: Bool       // default true: typo correction, section 11A (ENG-R1119); 1.1.0
    public init(inputMethod: InputMethod = .telex(TelexOptions()),
                toneStyle: ToneStyle = .traditional,
                autoRestore: Bool = true,
                appContext: AppContext = .general,
                historyLimit: Int = 16,
                lookaheadRevision: Bool = true,
                lineStartRevision: Bool = true,
                typoCorrection: Bool = true)       // 1.1.0
}

public struct KeyInput: Sendable, Hashable {
    public var character: Character
    public var fromKeypad: Bool
    public var capsLock: Bool         // Caps Lock was on for this key (ENG-R906)
    public init(_ character: Character, fromKeypad: Bool = false, capsLock: Bool = false)
}

public enum ResetReason: Sendable, Hashable {
    case cursorMoved, pointerClicked, focusChanged, applicationChanged,
         inputSourceChanged, secureInputChanged, eventTapReenabled,
         shortcut, forwardDelete, modeToggled, configurationChanged, unknown,
         unseenInput   // input reached the app that the host never saw (PLT-R397A)
}

public enum EngineEvent: Sendable, Hashable {
    case key(KeyInput)
    case backspace
    case restoreToggle
    case reset(ResetReason)
}

public struct TextEdit: Sendable, Hashable {
    public var deleteCount: Int        // grapheme clusters before the cursor
    public var deleteUTF16Count: Int   // the same span in UTF-16 code units
    public var insert: String          // NFC, may be empty
}

public enum KeyAction: Sendable, Hashable {
    case passThrough
    case edit(TextEdit, thenPassThrough: Bool)
}

public enum CommitRule: Sendable, Hashable {
    case unchanged, userChoice, userList, abbreviation, camelCase, escape, toneRemoval,
         invalid, extendedSpelling, notEnglish, notAttested,
         codeContext, boundaryParticle, phrase, learned,
         englishRun, ambiguityTable, techList, defaultVietnamese
}

public enum CommitDecision: Sendable, Hashable {
    case kept(CommitRule)
    case restored(CommitRule)
    case macro            // section 11
    case corrected(CommitRule)   // section 11A (ENG-R1115), 1.1.0: the rule of 8.1 that would have decided the token
}

public struct MacroTable: Sendable {
    public struct Entry: Sendable, Hashable {
        public var trigger: String      // 1...32 printable ASCII, no whitespace
        public var expansion: String    // NFC, at most 4,000 characters
        public var adaptCase: Bool      // default true
        public init(trigger: String, expansion: String, adaptCase: Bool = true)
    }
    public init(_ entries: [Entry]) throws   // throws on invalid or conflicting triggers (ENG-R1101, ENG-R1103)
    public static let empty: MacroTable
}

public enum LearningSignal: Sendable, Hashable {
    case preferredRaw(raw: String)
    case preferredVietnamese(raw: String)
    case neverCorrect(raw: String)          // section 11A (ENG-R1118), 1.1.0: a correction the user undid
}

public struct EngineOutput: Sendable, Hashable {
    public var action: KeyAction
    public var composingText: String
    public var decision: CommitDecision?
    public var learning: LearningSignal?
    public var revision: RevisionReason?            // the commit also revised the previous token (ENG-R828)
    public var collisionSignals: [CollisionSignal]  // ENG-R864; empty for most events
}

public enum RevisionReason: Sendable, Hashable { case phrase, particleTail, nextEnglish, nextVietnamese, lineVietnamese }

public enum CollisionContext: Sendable, Hashable, CaseIterable {
    case sentenceStart, afterVietnamese, afterEnglish, afterNeutral
}
public enum CollisionVote: Sendable, Hashable { case english, vietnamese, conflict }

public struct CollisionMemorySnapshot: Sendable, Hashable {     // ENG-R863, ENG-R865
    public struct Vote: Sendable, Hashable {
        public var word: String                 // a word of the bundled collision list
        public var context: CollisionContext?   // nil: the any-context entry
        public var choice: CollisionVote
    }
    public init<S: Sequence>(_ votes: S) where S.Element == Vote
    public static let empty: CollisionMemorySnapshot
    public var isEmpty: Bool { get }
    public func vote(word: String, context: CollisionContext) -> Language?
}

public struct CollisionSignal: Sendable, Hashable {              // ENG-R864, ENG-R866
    public enum Strength: Sendable, Hashable { case strong, weak }
    public var word: String
    public var context: CollisionContext
    public var side: Language
    public var strength: Strength
}

public struct EngineState: Sendable, Hashable {
    public static let initial: EngineState
    public var activeDisplay: String { get }
    public var activeRawKeys: String { get }
    public var isLiteral: Bool { get }
    public var historyCount: Int { get }
}

public struct WordSet: Sendable {
    public init<S: Sequence>(_ words: S) where S.Element == String
    public func contains(_ word: some StringProtocol) -> Bool
}

public enum Language: Sendable, Hashable { case vietnamese, english }

public enum VietnameseReadingKind: Sendable, Hashable { case particle, function, content }

public struct PhraseList: Sendable {                             // ENG-R826
    public init<S: Sequence>(_ phrases: S) where S.Element == String
    public let count: Int
    public static let empty: PhraseList
}

public struct CollisionLists: Sendable {                         // 8.2, ENG-R825 to ENG-R828
    public var phrases: PhraseList, supplement: WordSet, boundaryParticles: WordSet, runExempt: WordSet
    public var readingKinds: [String: VietnameseReadingKind]
    public var englishFunctionWords: WordSet, englishLean: WordSet
    public var tailWords: WordSet, tailParticles: WordSet, preGuard: WordSet
    public init(/* every list, each defaulting to empty */)
    public static let empty: CollisionLists
}

public struct ApproximateWordSet: Sendable {                     // section 11A (ENG-R1120), 1.1.0: a Bloom filter over lowercase words
    public init(bits: [UInt64], hashCount: Int, wordCount: Int)  // the stored form; bits.count a power of two
    public init<S: Sequence>(exactly words: S, bitsPerWord: Int = 12, hashCount: Int = 8) where S.Element == String
    public init<S: Sequence>(exactly words: S, bitCount: Int, hashCount: Int) where S.Element == String
    public func mayContain(_ word: some StringProtocol) -> Bool  // never false for a word it holds
    public var bits: [UInt64] { get }
    public var hashCount: Int { get }
    public var wordCount: Int { get }
    public static let empty: ApproximateWordSet                  // answers false for every word
}
// Hashing: FNV-1a 64 over the UTF-8 bytes gives h1; h2 = h1 rotated left by 32 bits, forced odd; the i-th index
// is (h1 + i * h2) mod 2^64, masked by bitCount - 1. No process seed, so the builder and the loader agree.

public struct PackedWordSet: Sendable {                          // section 11A (ENG-R1120), 1.1.0: the shapes and keyings
    public init<S: Sequence>(_ words: S) where S.Element == String
    public func contains(_ word: some StringProtocol) -> Bool
    public var count: Int { get }
    public static let empty: PackedWordSet
}
// Packing: a word of 1 to 12 letters a-z is one UInt64, 5 bits per letter (a = 1 ... z = 26, 0 ends the word), the
// first letter in the highest of the 60 low bits, so the values sort as the words' bytes do; the set is the sorted
// array of the values and a lookup is a binary search. Any other word is kept apart in an ordinary set.

public struct CorrectionData: Sendable {                         // section 11A (ENG-R1120), 1.1.0
    public let guardList: ApproximateWordSet                     // rarer English words and proper names; may answer yes for a word it lacks
    public let keyboardNeighbours: [Character: String]           // the QWERTY table of ENG-R1113
    public let unmarkedShapes: PackedWordSet                     // generated from the tier tables (ENG-R1110 (d))
    public let vietnameseKeyings: PackedWordSet                  // usual-order Telex keys of Tier A syllables (ENG-R1125); generated, never empty
    public init(guardList: ApproximateWordSet, keyboardNeighbours: [Character: String],
                unmarkedShapes: PackedWordSet, vietnameseKeyings: PackedWordSet)
    public init(guardList: ApproximateWordSet, keyboardNeighbours: [Character: String],
                unmarkedShapes: WordSet, vietnameseKeyings: WordSet)   // packs the two sets
    public static let empty: CorrectionData
}

public struct Resources: Sendable {
    public init(english: WordSet, techAlways: WordSet, techCodeOnly: WordSet,
                techCodeCapitalized: WordSet = WordSet([]),   // 8.2, ENG-R850
                attestedSyllables: WordSet, ambiguity: [String: Language],
                userKeepRaw: WordSet, userKeepVietnamese: WordSet,
                macros: MacroTable = .empty,
                collision: CollisionLists = .empty,
                collisionMemory: CollisionMemorySnapshot = .empty,
                userNeverCorrect: WordSet = WordSet([]),      // section 11A (ENG-R1118), 1.1.0
                correction: CorrectionData = .empty)          // section 11A (ENG-R1120), 1.1.0
    public static let empty: Resources
}

public struct Engine: Sendable {
    public init(configuration: EngineConfiguration, resources: Resources)
    public func reduce(_ state: EngineState, _ event: EngineEvent) -> (EngineState, EngineOutput)
}

public struct Session: Sendable {
    public init(engine: Engine, state: EngineState = .initial)
    public private(set) var state: EngineState
    public mutating func handle(_ event: EngineEvent) -> EngineOutput
}

public enum Validity: Sendable, Hashable { case standard, extended, invalid }
public enum Tone: Int, Sendable, Hashable { case level, acute, grave, hook, tilde, dot }

public struct SyllableAnalysis: Sendable, Hashable {
    public var onset: String
    public var vowelGroup: String
    public var coda: String
    public var tone: Tone
    public var validity: Validity
    public var toneLetterOffset: Int?   // offset in characters, nil if no tone
}

public enum Orthography {
    public static func analyze(_ word: String) -> SyllableAnalysis
    public static func validity(of word: String) -> Validity
}

// In VietnameseEngineData:
extension Resources {
    public static func bundled(userKeepRaw: WordSet, userKeepVietnamese: WordSet,
                               macros: MacroTable = .empty,
                               collisionMemory: CollisionMemorySnapshot = .empty,
                               userNeverCorrect: WordSet = WordSet([])) throws -> Resources   // 1.1.0: loads CorrectionData too
}
```

*(Amendment of 19/11/2026, the API stage of 1.1.0, recorded again in `docs/decisions/0203-correction-data.md`.)* Five changes to the 1.1.0 lines above: (1) the new public type `ApproximateWordSet`; (2) `CorrectionData.guardList` is an `ApproximateWordSet`, not a `WordSet`, which cannot answer yes for a word it lacks; (3) the fields of `CorrectionData` are constants with a public memberwise initialiser, because the engine derives its lookup structures from them, so they change only by assigning a new value to `Resources.correction`; (4) `EngineConfiguration.init` takes `typoCorrection` (the property was listed without its parameter); (5) `vietnameseKeyings` is generated by `lexicon-builder` and never empty (the earlier line allowed it to be empty when a parser computes the keyings; the parser is the named fallback of ENG-R1120, and 12.2 is amended again if it is ever taken).

*(Sixth amendment, 19/11/2026, the engine logic track of 1.1.0, recorded again in `docs/decisions/0203-correction-data.md` sections 6 and 8.)* (6) `CorrectionData.unmarkedShapes` and `vietnameseKeyings` are `PackedWordSet`s, a new public type, instead of `WordSet`s: a `Set<String>` keeps its load under 75 %, so the 27,277 bundled keyings took 65,536 buckets of 16 bytes (1 MB) on their own and the new data 1.30 MB, over the 1 MB of ENG-R1120. A packed set holds each word of 1 to 12 letters as one `UInt64` (the longest bundled keying has 9 letters, the longest shape 7), so the shapes, the keyings, the guard list, the neighbours table and the correction index together own 0.38 MB. The loader fills the sets from the sorted files without a sort, and the engine's index reads them in place, never a second copy. The lookup is a binary search: at most 15 comparisons for the keyings, a bound set by the bundled data and not by the lexicon, which counts among the lookups on preallocated tables of ENG-R1122 and is measured by ENG-T55. The initialiser that takes `WordSet`s is kept and packs them, so callers written against amendment (3) compile unchanged.

- **ENG-R1210** `Engine.reduce` MUST be deterministic and side-effect free: no clock, randomness, locale, environment or I/O. Same state and event give the same result.
- **ENG-R1211** Changing configuration means creating a new `Engine`; the host sends `reset(.configurationChanged)` with it. *(Amendment of 19/11/2026, `02-platform.md` PLT-R340, late focus change.)* One exception: a state that holds no committed token (no commit since the last reset) is the same under two configurations that differ only in `lookaheadRevision`, because that switch governs only decisions taken at a commit (ENG-R829); the host MAY continue such a state with the other engine (`Session(engine:state:)`) without a reset. Every other configuration change, and this one once a token was committed, keeps the rule above. `LookaheadRevisionContinuationTests` (AppCore) checks the equality with the bundled data for both methods, both contexts and auto restore on and off.
- **ENG-R1212** `Orthography.analyze` exists for the diagnostics window ("why did this word change?") and for tests. It works only on text the user explicitly pastes there.

### 12.3 Privacy

- **ENG-R1220** The engine MUST NOT log, print, persist or transmit keys or text. `CommitDecision` and `RevisionReason` reason codes contain no text; `LearningSignal` contains text only so the host can update a user list the user can see. `CollisionSignal.word` is a word of the bundled collision list, never other text; it exists so that the host can store and display the user's choice (ENG-R866).

### 12.4 Performance budget

- **ENG-R1230** Per event, release build, measured on the slowest supported Apple Silicon machine (baseline: M1): p50 at most 5 µs, p99 at most 25 µs, p99.9 at most 100 µs, including commits and macro lookups. Worst case seen in a 10-million-event fuzz run: at most 1 ms. These numbers are the single source for the engine budget; `02-platform.md` PLT-R307 and `04-quality-release.md` QA-R14 reference them. No M1 is available, so the committed benchmark baseline was measured on an M4 and says so (decision of the product owner, 13/11/2026).
- **ENG-R1231** `Resources.bundled` loads in at most 50 ms and resident memory for all resources is at most 8 MB.
- **ENG-R1232** Per-event work SHOULD be proportional to the token length, not to the history or lexicon size (lexicon lookups by hash or trie).
- **ENG-R1233** CI MUST fail when the performance test exceeds the budget by more than 20 % on the CI machine after calibration against a fixed reference benchmark.

---

## 13. Acceptance tests

### 13.1 Independent oracle

- **ENG-T01** `VietnameseEngineTesting` MUST contain an oracle that produces expected strings directly from the tables of section 3 and the rules of section 5 (spelling a syllable from onset, rhyme, tone and style), without calling the engine's composition code. The engine is tested against it.

### 13.2 Generated Vietnamese corpus

- **ENG-T02** For every Tier A onset-rhyme pair (3,367), every allowed tone (15,406 toned syllables), both input methods and both tone styles, generate these key sequences and assert that the display after the last key, and the committed text after a space in Vietnamese context, equal the oracle:
  - **O1 canonical:** letters in order, each modifier key right after the letter it modifies, the `w` (VNI `7`) of `ươ` after the `o`, stroke key right after `d`, tone key last.
  - **O2 tone before coda:** as O1 but the tone key right after the vowel group.
  - **O3 everything at the end:** base letters only, then stroke, modifier keys and tone key after the last letter.
  - **O4 tone early:** tone key right after the first letter of the vowel group (exercises relocation).
  - In Telex, the loan rhymes `oong` / `ooc` need the escape: the literal `oo` is typed `ooo` (`booong` -> `boong`).
- **ENG-T03** Variants for every Tier A toned syllable with Telex O1: Titlecase (first key uppercase), all uppercase, and for every toned syllable whose rhyme contains `ươ` the explicit `uwow` spelling (31,676 variant cases: 2 x 15,406 + 864).
- **ENG-T04** The O1 to O4 corpus has 237,824 cases (each toned syllable contributes 2 methods x 2 styles x 4 orders, 3 orders for the level tone), plus the 31,676 ENG-T03 variants; the generator prints the current counts (ENG-R350). The implementation MUST pass 100 % of them. *(The first version quoted the reference model's 237,916 cases and 30,928 variants, which counted the spelling `giu` twice and covered `uwow` for the level tone only; see 3.15.)*

### 13.3 English corpus

- **ENG-T10** The English lexicon (8.2) plus both tech lists, each word typed in Telex with default options followed by a space: (a) after a seed English token (English run) and (b) after a seed Vietnamese token. Assert ENG-R871 and ENG-R872. The test prints the full list of changed words with the rule that changed them.
- **ENG-T11** Documented exceptions live in `known-exceptions.txt` (word, display, rule, reason). Adding an exception requires review by Pa.
- **ENG-T12** Spot list that MUST stay unchanged after commit with defaults in any context: `text user case wifi USB data verbose password traffic boss coffee less tomorrow mother keyboard startup facebook java year plans grows ask zoom two wow does www`.

### 13.4 Vietnamese prose corpus

- **ENG-T20** At least 200,000 syllables of legally safe Vietnamese text (8.2) split into tokens; each token typed by three simulated typists (canonical, tone at end, free order with modifiers after the coda); assert ENG-R873.

### 13.5 Regression list

| ID | Lesson (from the audit and user reports) | Requirements | Examples / tests |
|---|---|---|---|
| REG-01 | `qu` + tone removal with no vowel crashed | ENG-R411 | W153-W155, W183, `qqz`, `Quzhou`, `qut0` |
| REG-02 | Restoring tokens longer than 32 keys crashed (fixed-size buffers) | ENG-R640, ENG-R641 | fuzz with 33, 64, 1,000 and 100,000-key tokens; restore equals raw |
| REG-03 | English restore off by default and needing a download; `text user case wifi USB` got marks | ENG-R106, 8.1 | B001-B007, ENG-T12 |
| REG-04 | Quick Telex on by default (`cc` -> `ch`, `kkk` -> `khk`) | ENG-R121 | `cc kkk nn tt gg TT` stay as typed |
| REG-05 | VNI restore/undo emitted Telex keys | ENG-R403, ENG-R705 | E03, `ba6c3` commit -> `ba6c3` (B047) |
| REG-06 | Legacy encodings broken | ENG-R102, ENG-R120 | every insert string is NFC with no combining marks |
| REG-07 | Backspacing across `", "`, `". "`, double space lost the previous word | ENG-R1002 | `chao`, space, Backspace, `f` -> `chào`; same with `", "`, `". "`, two spaces |
| REG-08 | Restore damaged valid words and names; rhyme `uych` missing | 3.7, ENG-R843 | W226-W235, B036-B039, `huých`, `huỵch`, `tọe` kept |
| REG-09 | Tone/modifier keys after the coda were ignored | ENG-R430 | W033-W060, W170-W174 |
| REG-10 | `did` typed `ddid` was "corrected" to `ddi` | ENG-R440, L4 | W136, B015 |
| REG-11 | Wrong tone position for `uy` (style), `xoáy`, `giúp` typed with tone on `i` | 5.1, 5.2, ENG-R307 | W062-W067, W073, W104, W194 |
| REG-12 | `thuơ` stuck on `w`; `ươi` could not switch to `uôi`; `thuo` + `w` could not continue to `thương` | 5.5 | W121-W130 |
| REG-13 | Stretched words lost or moved marks (`ừa` + `aaa`, `nhé` + `ee`, `chưa` + `a` -> `chưâ`) | ENG-R416, ENG-R441 | W141-W146, W149-W150 |
| REG-14 | VNI turned `@`, `(` and other shifted digits into marks | ENG-R401, ENG-R402 | `o@gmail.com` stays as typed; `(đây là ví dụ)` keeps the brackets |
| REG-15 | Brackets became `ư` / `?` | ENG-R104 | `[[` and `]]` stay brackets by default; W244-W245 with the option |
| REG-16 | QWERTZ `y`/`z` confusion | section 2, `KeyInput` | engine receives characters only; host test with QWERTZ, AZERTY, Dvorak |
| REG-17 | `ĐL` (abbreviation of `Đà Lạt`) restored to `DDL` | ENG-R840 | B040, B041 |
| REG-18 | First word after re-focusing a field not restored | ENG-R832, ENG-R1012 | `reset(.focusChanged)` then `verbose` + space -> `verbose ` |
| REG-19 | English word received two marks (`password`) | ENG-R420 | W221, B008 |
| REG-20 | `qw` gave `qư`; `hw`, `thw`, `chw` did not give `ư`; users wanted `w` off | ENG-R413, ENG-R103 | W039-W041, W223-W224, W246-W248 |
| REG-21 | `dda` gave `â` | ENG-R415 | `dda` -> `đa` |
| REG-22 | Engine not reset when the tap was re-enabled | ENG-R1010, ENG-R1011 | `reset(.eventTapReenabled)` clears token and history |
| REG-23 | Debug mode wrote keystrokes to a file | ENG-R1220 | static check: no logging or I/O symbols in the core |
| REG-24 | After deleting an extra tone key the tone could not be re-applied. Since 15/11/2026 the Backspace takes the tone key with the escape letter, so the tone kind is no longer escaped and the next tone key applies (`nhaamff` + Backspace gives `nhâm`, then `f` gives `nhầm`) | ENG-R711, ENG-R441 | W241, W242a |
| REG-25 | Teencode `zá` impossible because `z` always meant tone removal | ENG-R411, Tier B `z` | W156-W157 |
| REG-26 | Misspellings `nghãi`, `nghô` accepted | 3.10, ENG-R420 | B044, B045 |
| REG-27 | Restore after doubled letters lost a letter (`traffic` -> `trafic`) | L4 | W148, B009 |
| REG-28 | (Product owner, P0-2) Slang onset `dz` could not be typed: the predecessor only allowed one-letter extra onsets | 3.3 `dz`, ENG-R316 | W249-W252, B053-B054 |
| REG-29 | (Product owner, P0-2) `hẹo` worked "sometimes": a dictionary without `hẹo` restored it to `heoj` at Space but not at a comma, because only Space triggered restore | ENG-R316, ENG-R910 | W253, B055-B056 |
| REG-30 | (Product owner, P0-3) English restore fired only on Space; `, . ; : ! ?` and the like left `tẽt`, so the user had to type Space then Backspace | ENG-R910, 9 (boundary table), ENG-R803 | B057-B064 |
| REG-31 | (Product owner, 14/11/2026) Backspace changed a letter it did not delete: one `w` on `uo` lost its horn on `ư` with the `ơ` (`thuowr` + Backspace -> `thu`) | ENG-R710, ENG-R714 | W243a-W243j, ENG-T38 |
| REG-32 | (Product owner, 14/11/2026) An English loanword in a Vietnamese sentence made the run English, so the next collision was restored: `cũng tricky as` committed `as` instead of `á`, `trên server been` kept `been` | ENG-R823, L10 | B065-B072 |
| REG-33 | (Product owner, 15/11/2026, dev trace) Retyping a word re-opened after an automatic restore stayed as typed: `tiesng`, space, five Backspaces, `eesn` showed `tieesn`, not `tiến` | ENG-R1005 | W243k-W243o |
| REG-34 | (Product owner, 15/11/2026) A second tone-removal press did nothing useful: `daauszz` gave `dâuz` where `dau` was expected | ENG-R411 | W158a-W158j, W184a-W184c, W242n, W242o, W242s, W242t |
| REG-35 | (Product owner, 15/11/2026, dev trace in iTerm2) In the code context a Vietnamese word was turned into a shell command whatever the words around it: `Suwar looxi chinhs tar"` committed `Sửa lỗi chính tar"` | ENG-R850, L9 | B035-B035i, B064a, B064b |
| REG-36 | (Product owner, 16/11/2026, retest in iTerm2 of build 20261115g) A Vietnamese sentence that started with a code-only word stayed English: `Tar thuwr cais nayf` gave `Tar thử cái này` where `Tả thử cái này` was meant (since the product owner's rule of the same day, a first word in sentence case committed by a space is decided at its own commit, and RV5 revises a lowercase first word: `tar thuwr` gives `tả thử`) | ENG-R850 (L9, sentence condition), ENG-R828 RV5 | B035j-B035n, B064c, K01-K25 |
| REG-37 | (Product owner, 17/11/2026) English words that hit an escape were committed as the escaped form: `leecher` gave `lecher` (the third `e` escaped the circumflex of `lêch` and neither form is in the lexicon; about 4,600 such words in `/usr/share/dict/words`, `cheeseburger`, `coffeehouse`, `cookout`), and `turn off the light` gave `turn of the light`, `dessert` gave `desert`, `costs` gave `cots` (both forms English, L4 kept the escaped one) | ENG-R804, L4 | X01-X24 (13.9.5), `Tests/VietnameseEngineTests/Corpus/escape-regression.txt` |
| REG-38 | (Product owner, 18/11/2026) In the code context a code-only command whose keys are not English became a Vietnamese word wherever it stood, because L6 and L7 decided before L9: `sudo chown -R` committed `sudo chơn -R`, `ps -ef` committed `ps -è` | ENG-R850, L9 (right after L5 for a code-only word whose keys are not English, ENG-R801) | B035o-B035t, K26-K32 |
| REG-39 | (Product owner, 18/11/2026, Q9 of section 15) The text a tone-removal key left was restored at commit when it was no syllable: `dduwowngfzz` showed `duong` and Space gave `dduwowngfzz`, `vieejtz` gave `vieejtz` | ENG-R411, L4a | B052a-B052d, `ToneRemovalCommitTests` |
| REG-40 | (Product owner, 20/11/2026, on 1.0.1-beta.2) A `w` doubled out of habit (input methods where `w` alone gives `ư`) came back at commit: `wwebview` showed `webview` and Space gave `wwebview`, and so did `wwebsite`, `wwebhook`, `wwiki`, `wwidget`, `wwechat`, `wwordpress`, `Wwebview` and `vieejt wwebview`, because rule L4 (d) restored the raw keys with both `w` | ENG-R804 (the `w` doubling, the habit, `R′`, (c′), (d)), L4, ENG-R904 (L3b), ENG-R701, ENG-R803, ENG-R1005, ENG-R1117, 11A (the typed word) | X28-X39 (13.9.5), `WDoublingCommitTests`, `EscapeCommitRealDataTests`, `WDoublingFuzzRealDataTests`, `RegressionTests` |
| REG-41 | (Product owner, 22/11/2026) A capitalised word typed `Ww` with the habit of REG-40 came out in lowercase: `Wwade` (Shift+W, then w, a, d, e) showed and committed `wade`, `Wwarden` gave `warden`, because the escape appended its own key, a lowercase `w`, and rule L4 (b) or the deliberate form of (d) kept that display (34 of the 337 capitalised words of `/usr/share/dict/words` that start with `W`) | ENG-R903 (the escaped letter of a standalone `w` doubling), ENG-R440, ENG-R442, ENG-R804 (d), ENG-R904 | X29, X40-X43 (13.9.5), `WDoublingCommitTests`, `EscapeCommitRealDataTests`, `WDoublingFuzzRealDataTests`, `RegressionTests` |
| REG-42 | (Product owner, 23/11/2026, on 1.1.0-beta.1) Escape right after an automatic restore did not give the Vietnamese word back: typing `Thanks Giving bả với KT qua nhà ổng ở Ohio chơi`, the space after `bar` restored it because the two words before are English (rule L10), and Escape right after passed through (ENG-R703); passed through, it was a hard boundary in the host, so the revision the next Vietnamese word makes (RV4, `bả với`) did not come either and the line kept `bar với` | ENG-R703, ENG-R704, ENG-R706, ENG-R829, ENG-R861, ENG-R864 | E09-E13 (13.10), `ContextRestoreUndoTests`, `ContextRestoreUndoRealDataTests`, `RegressionTests` |

### 13.6 Fuzz invariants

Run at least 1,000,000 random events per pull request and 100,000,000 nightly, over the alphabet of ASCII letters (both cases), digits, punctuation, space, Return, Tab, a few non-ASCII letters, Backspace, restore toggle and every reset reason, with token lengths up to 100,000 keys, with and without a macro table of 1,000 random triggers (including punctuation-only triggers).

- **ENG-T30 No crash.** No trap, no precondition failure, no unbounded memory growth beyond the configured history.
- **ENG-T31 Simulated field.** Applying every action to a simulated text field (passThrough inserts the key or deletes one character for Backspace) yields, after every event, a text whose tail equals the engine's view (history plus active display). The engine never asks to delete more characters than it produced.
- **ENG-T32 Restore is exact.** For any token, `restoreToggle` produces exactly the raw keys typed since the token started (after Backspace edits); a token that already shows them, or a re-opened token that shows `R′` after rule L4 or L3b (ENG-R804, ENG-R904, ENG-R1005), composes instead (ENG-R701 second branch). A second toggle right after it passes through and changes nothing (ENG-R702); a toggle that follows any other event (for example Backspace and then the toggle, E02b) returns the composed display (ENG-R701 second branch). With no active token, a toggle right after a commit that rule L10 or L9b restored because of the tokens before it, when the token alone would keep it, turns the restored keys and the boundary character into exactly the composed form `C` and the same boundary character (ENG-R706, REG-42), and a toggle right after any other commit passes through unless it undoes a revision or a correction (ENG-R703, ENG-R829, ENG-R1117).
- **ENG-T33 Determinism and replay.** Replaying the same events from `.initial` gives identical outputs; an incremental implementation equals full replay at every step.
- **ENG-T34 Encoding.** Every inserted string is NFC, contains no combining marks, and `deleteCount == deleteUTF16Count` for every edit.
- **ENG-T35 Method isolation.** In VNI, no output character is a letter that was not typed, except the Vietnamese letters derived from typed letters; in particular `w` appears only if typed.
- **ENG-T36 Escape.** For every transform key K and token T where K applies, T + K + K ends with the literal K. The literal K takes the case of the escaping key, except in a standalone `w` doubling, where it is a capital when either key is one (ENG-R903, REG-41: T empty, `W` then `w` ends with `W`). The tone-removal key removes one layer per press (ENG-R411: the tone, then the marks), so for it T + K + K + K does.
- **ENG-T37 Viability.** No display in composing mode is non-viable.
- **ENG-T38 Backspace only deletes.** Every Backspace takes exactly the last character of the field and leaves the other characters as they were, except the documented exceptions of ENG-R714; no Backspace edit deletes more than the active token's display. Checked on the fuzz streams and as a property test: every generated syllable (ENG-T02 orders O1 to O4 in Telex and VNI, both tone styles, the ENG-T03 variants, plus the horn-first orders Telex `uwo` and VNI `u7o`, the horn and circumflex changes of mind of ENG-R533, Telex standalone `w`, and a mixed-case spelling), the English lexicon and both tech lists (Telex in three casings and VNI) and the distinct words of the prose corpus (three typists, Telex and VNI) are typed, then Backspace is pressed until the field is empty, once before any boundary and once after a space (the first Backspace re-opens the word, ENG-R1002, ENG-R1003). The same check runs on every key sequence of up to five keys over small alphabets of transform keys (Telex with escapes, tone and mark removals and the standalone `w`; Telex with bracket keys, in both cases; VNI; Telex followed by a space) and of up to six keys over the strokes, tones, standalone `w` and bracket keys of Telex, where key orders that no word has meet (`wsaw`, `wzow`, `]ous]`, `dwndw`, `dwnsdw`; ENG-R710, ENG-R711).
- With `typoCorrection` on (section 11A, 1.1.0) the run also checks ENG-T54, which restates ENG-T32 and ENG-T35 for corrected tokens.

### 13.7 Performance test

- **ENG-T40** A benchmark replays the prose corpus (13.4) with the three typists and a fuzz stream, records per-event latency and asserts ENG-R1230 and ENG-R1231.

### 13.8 Worked examples: composition (296 rows)

Keys are typed in order; `⌫` means Backspace. "Output before boundary" is the display after the last key, before any space. A space inside the keys is typed like any other key (W243h, W243i: it commits the word, and the next Backspace re-opens it). Every row was checked against the reference model, except W243k-W243o, which depend on the restore decisions of section 8 that the model leaves out, and W249-W253, which the model predates (reference-model README, known gap 2); the implementation's test suite MUST contain all of them. Rows W243a-W243j were added after W243 on 14/11/2026 (REG-31), and rows W158a-W158j, W184a-W184c, W242a-W242w and W243k-W243o on 15/11/2026 (REG-24, REG-33, REG-34); the letter suffix keeps the numbers of the rows after them. An empty output cell (two backticks) means the token is empty.

| # | Group | Method | Style | Options | Keys typed | Output before boundary | Note |
|---|---|---|---|---|---|---|---|
| W001 | Basic Telex | Telex | trad | - | `as` | `á` |  |
| W002 | Basic Telex | Telex | trad | - | `af` | `à` |  |
| W003 | Basic Telex | Telex | trad | - | `ar` | `ả` |  |
| W004 | Basic Telex | Telex | trad | - | `ax` | `ã` |  |
| W005 | Basic Telex | Telex | trad | - | `aj` | `ạ` |  |
| W006 | Basic Telex | Telex | trad | - | `aa` | `â` |  |
| W007 | Basic Telex | Telex | trad | - | `aw` | `ă` |  |
| W008 | Basic Telex | Telex | trad | - | `ee` | `ê` |  |
| W009 | Basic Telex | Telex | trad | - | `oo` | `ô` |  |
| W010 | Basic Telex | Telex | trad | - | `ow` | `ơ` |  |
| W011 | Basic Telex | Telex | trad | - | `uw` | `ư` |  |
| W012 | Basic Telex | Telex | trad | - | `dd` | `đ` |  |
| W013 | Basic Telex | Telex | trad | - | `w` | `ư` | standalone w is a vowel (option on) |
| W014 | Basic Telex | Telex | trad | - | `vieetj` | `việt` |  |
| W015 | Basic Telex | Telex | trad | - | `nam` | `nam` |  |
| W016 | Basic Telex | Telex | trad | - | `tieengs` | `tiếng` |  |
| W017 | Basic Telex | Telex | trad | - | `dduwowcj` | `được` |  |
| W018 | Basic Telex | Telex | trad | - | `nguwowif` | `người` |  |
| W019 | Basic Telex | Telex | trad | - | `khoong` | `không` |  |
| W020 | Basic Telex | Telex | trad | - | `chaof` | `chào` |  |
| W021 | Basic Telex | Telex | trad | - | `banj` | `bạn` |  |
| W022 | Basic Telex | Telex | trad | - | `cuar` | `của` | ua diphthong: tone on u |
| W023 | Basic Telex | Telex | trad | - | `muaf` | `mùa` |  |
| W024 | Basic Telex | Telex | trad | - | `muwaf` | `mừa` | ưa: tone on ư (modified letter) |
| W025 | Basic Telex | Telex | trad | - | `mias` | `mía` | ia diphthong: tone on i |
| W026 | Basic Telex | Telex | trad | - | `tooi` | `tôi` |  |
| W027 | Basic Telex | Telex | trad | - | `ddaauf` | `đầu` |  |
| W028 | Basic Telex | Telex | trad | - | `nhaf` | `nhà` |  |
| W029 | Basic Telex | Telex | trad | - | `cos` | `có` |  |
| W030 | Basic Telex | Telex | trad | - | `nhuwng` | `nhưng` |  |
| W031 | Basic Telex | Telex | trad | - | `trowif` | `trời` |  |
| W032 | Basic Telex | Telex | trad | - | `nuwowcs` | `nước` |  |
| W033 | Free-order entry | Telex | trad | - | `tieesng` | `tiếng` | tone before coda |
| W034 | Free-order entry | Telex | trad | - | `caanf` | `cần` | tone after coda (REG-09) |
| W035 | Free-order entry | Telex | trad | - | `caafn` | `cần` |  |
| W036 | Free-order entry | Telex | trad | - | `hopwj` | `hợp` | w and tone after coda (REG-09) |
| W037 | Free-order entry | Telex | trad | - | `howjp` | `hợp` |  |
| W038 | Free-order entry | Telex | trad | - | `dangd` | `đang` | đ key after the rhyme |
| W039 | Free-order entry | Telex | trad | - | `chwa` | `chưa` | standalone w then vowel |
| W040 | Free-order entry | Telex | trad | - | `hw` | `hư` |  |
| W041 | Free-order entry | Telex | trad | - | `thw` | `thư` |  |
| W042 | Free-order entry | Telex | trad | - | `swr` | `sử` |  |
| W043 | Free-order entry | Telex | trad | - | `wsng` | `ứng` |  |
| W044 | Free-order entry | Telex | trad | - | `wngs` | `ứng` | tone after coda (REG-09) |
| W045 | Free-order entry | Telex | trad | - | `twngf` | `từng` |  |
| W046 | Free-order entry | Telex | trad | - | `ddeens` | `đến` |  |
| W047 | Free-order entry | Telex | trad | - | `ddeesn` | `đến` |  |
| W048 | Free-order entry | Telex | trad | - | `muoons` | `muốn` |  |
| W049 | Free-order entry | Telex | trad | - | `moojt` | `một` | tone before coda |
| W050 | Free-order entry | Telex | trad | - | `mootj` | `một` | tone after coda (REG-09) |
| W051 | Free-order entry | Telex | trad | - | `phucws` | `phức` | w and tone after coda (REG-09) |
| W052 | Free-order entry | Telex | trad | - | `tapj` | `tạp` |  |
| W053 | Free-order entry | Telex | trad | - | `conf` | `còn` |  |
| W054 | Free-order entry | Telex | trad | - | `hangf` | `hàng` |  |
| W055 | Free-order entry | Telex | trad | - | `chinhs` | `chính` |  |
| W056 | Free-order entry | Telex | trad | - | `xacs` | `xác` |  |
| W057 | Free-order entry | Telex | trad | - | `tawts` | `tắt` | (REG-09) |
| W058 | Free-order entry | Telex | trad | - | `trawngs` | `trắng` |  |
| W059 | Free-order entry | Telex | trad | - | `hawngf` | `hằng` |  |
| W060 | Free-order entry | Telex | trad | - | `tucj` | `tục` | (REG-09) |
| W061 | Free-order entry | Telex | trad | - | `nguyeenx` | `nguyễn` |  |
| W062 | Tone placement | Telex | trad | - | `hoaf` | `hòa` | open oa, traditional style |
| W063 | Tone placement | Telex | modern | - | `hoaf` | `hoà` | open oa, modern style |
| W064 | Tone placement | Telex | trad | - | `khoer` | `khỏe` | open oe, traditional |
| W065 | Tone placement | Telex | modern | - | `khoer` | `khoẻ` | open oe, modern |
| W066 | Tone placement | Telex | trad | - | `thuyr` | `thủy` | open uy, traditional |
| W067 | Tone placement | Telex | modern | - | `thuyr` | `thuỷ` | open uy, modern (REG-11) |
| W068 | Tone placement | Telex | trad | - | `hoafn` | `hoàn` | coda present: same in both styles |
| W069 | Tone placement | Telex | modern | - | `hoafn` | `hoàn` | coda present: same in both styles |
| W070 | Tone placement | Telex | trad | - | `toans` | `toán` |  |
| W071 | Tone placement | Telex | trad | - | `huyts` | `huýt` |  |
| W072 | Tone placement | Telex | trad | - | `huynhf` | `huỳnh` |  |
| W073 | Tone placement | Telex | trad | - | `xoays` | `xoáy` | three-letter group: middle letter (REG-11) |
| W074 | Tone placement | Telex | trad | - | `hoaif` | `hoài` |  |
| W075 | Tone placement | Telex | modern | - | `ngoaif` | `ngoài` |  |
| W076 | Tone placement | Telex | trad | - | `khuyur` | `khuỷu` | uyu |
| W077 | Tone placement | Telex | trad | - | `ngoeoj` | `ngoẹo` | oeo |
| W078 | Tone placement | Telex | trad | - | `tuooir` | `tuổi` |  |
| W079 | Tone placement | Telex | trad | - | `ruwowuj` | `rượu` |  |
| W080 | Tone placement | Telex | trad | - | `hieeur` | `hiểu` |  |
| W081 | Tone placement | Telex | trad | - | `yeeus` | `yếu` |  |
| W082 | Tone placement | Telex | trad | - | `khuyeenr` | `khuyển` |  |
| W083 | Tone placement | Telex | trad | - | `thuowr` | `thưở` | open ươ shown while typing; becomes thuở at the boundary |
| W084 | Tone placement | Telex | trad | - | `huow` | `hươ` | becomes huơ at the boundary |
| W085 | Tone placement | Telex | trad | - | `mwaf` | `mừa` |  |
| W086 | Tone placement | Telex | trad | - | `luwar` | `lửa` |  |
| W087 | Tone placement | Telex | trad | - | `cuwus` | `cứu` |  |
| W088 | Tone placement | Telex | trad | - | `guwir` | `gửi` |  |
| W089 | Tone placement | Telex | trad | - | `soocs` | `sốc` |  |
| W090 | Tone placement | Telex | trad | - | `sooocs` | `soóc` | oo escape gives the loan rhyme ooc; tone on second o |
| W091 | Tone placement | Telex | trad | - | `boooong` | `booong` | escape is sticky: no fourth-o circumflex |
| W092 | Tone placement | Telex | trad | - | `booong` | `boong` | loan rhyme oong |
| W093 | Tone placement | Telex | trad | - | `huychj` | `huỵch` | rhyme uych |
| W094 | Tone placement | Telex | trad | - | `tuyps` | `tuýp` |  |
| W095 | Tone placement | Telex | trad | - | `oaf` | `òa` |  |
| W096 | Tone placement | Telex | modern | - | `oaf` | `oà` |  |
| W097 | Tone placement | Telex | trad | - | `uyr` | `ủy` |  |
| W098 | Tone placement | Telex | modern | - | `uyr` | `uỷ` |  |
| W099 | Tone placement | Telex | trad | - | `hoeen` | `hoeen` | oê is not a nucleus: second e stays a letter, token goes literal |
| W100 | Tone placement | Telex | trad | - | `hueej` | `huệ` | uê: tone on ê |
| W101 | gi and qu onsets | Telex | trad | - | `giaf` | `già` |  |
| W102 | gi and qu onsets | Telex | trad | - | `gif` | `gì` |  |
| W103 | gi and qu onsets | Telex | trad | - | `gifn` | `gìn` | gi with no following vowel: i is the nucleus |
| W104 | gi and qu onsets | Telex | trad | - | `gisup` | `giúp` | tone typed on i, moves to u when u arrives (REG-11) |
| W105 | gi and qu onsets | Telex | trad | - | `giusp` | `giúp` |  |
| W106 | gi and qu onsets | Telex | trad | - | `giuwax` | `giữa` |  |
| W107 | gi and qu onsets | Telex | trad | - | `gieengs` | `giếng` | gi + iêng written giêng |
| W108 | gi and qu onsets | Telex | trad | - | `gieets` | `giết` |  |
| W109 | gi and qu onsets | Telex | trad | - | `giuwowngf` | `giường` |  |
| W110 | gi and qu onsets | Telex | trad | - | `gioir` | `giỏi` |  |
| W111 | gi and qu onsets | Telex | trad | - | `quar` | `quả` |  |
| W112 | gi and qu onsets | Telex | trad | - | `quys` | `quý` | u belongs to qu: tone on y in both styles |
| W113 | gi and qu onsets | Telex | trad | - | `quis` | `quí` |  |
| W114 | gi and qu onsets | Telex | trad | - | `quyeets` | `quyết` |  |
| W115 | gi and qu onsets | Telex | trad | - | `quoocs` | `quốc` | qu + ôc |
| W116 | gi and qu onsets | Telex | trad | - | `quowr` | `quở` | qu + ơ: no horn on the u of qu |
| W117 | gi and qu onsets | Telex | trad | - | `quawng` | `quăng` |  |
| W118 | gi and qu onsets | Telex | trad | - | `quaanf` | `quần` |  |
| W119 | gi and qu onsets | Telex | trad | - | `quyfnh` | `quỳnh` |  |
| W120 | gi and qu onsets | Telex | trad | - | `quaay` | `quây` | qu + ây |
| W121 | uo horn handling | Telex | trad | - | `tuowng` | `tương` |  |
| W122 | uo horn handling | Telex | trad | - | `tuwowng` | `tương` |  |
| W123 | uo horn handling | Telex | trad | - | `tuwong` | `tương` | horn on u only is completed to ươ |
| W124 | uo horn handling | Telex | trad | - | `thuowng` | `thương` |  |
| W125 | uo horn handling | Telex | trad | - | `cuwowis` | `cưới` |  |
| W126 | uo horn handling | Telex | trad | - | `cuwowiso` | `cuối` | o after ươ switches to uô (REG-12) |
| W127 | uo horn handling | Telex | trad | - | `cuoois` | `cuối` |  |
| W128 | uo horn handling | Telex | trad | - | `cuooisw` | `cưới` | w after uô switches to ươ |
| W129 | uo horn handling | Telex | trad | - | `huouw` | `hươu` | ươu |
| W130 | uo horn handling | Telex | trad | - | `thuoww` | `thuow` | second w escapes both horns (REG-12) |
| W131 | Escape by doubling | Telex | trad | - | `ass` | `as` |  |
| W132 | Escape by doubling | Telex | trad | - | `aaa` | `aa` |  |
| W133 | Escape by doubling | Telex | trad | - | `aww` | `aw` |  |
| W134 | Escape by doubling | Telex | trad | - | `ddd` | `dd` |  |
| W135 | Escape by doubling | Telex | trad | - | `ddi` | `đi` |  |
| W136 | Escape by doubling | Telex | trad | - | `ddid` | `did` | escape of đ (REG-10) |
| W137 | Escape by doubling | Telex | trad | - | `ww` | `w` | escape of standalone ư |
| W138 | Escape by doubling | Telex | trad | - | `www` | `ww` | escape is sticky; boundary may restore www from the tech list |
| W139 | Escape by doubling | Telex | trad | - | `uww` | `uw` |  |
| W140 | Escape by doubling | Telex | trad | - | `nhaamff` | `nhâmf` | escape of tone (REG-24) |
| W141 | Escape by doubling | Telex | trad | - | `nhes` | `nhé` |  |
| W142 | Escape by doubling | Telex | trad | - | `nhese` | `nhế` | e after é is a circumflex request |
| W143 | Escape by doubling | Telex | trad | - | `nhesee` | `nhée` | (REG-13) |
| W144 | Escape by doubling | Telex | trad | - | `chuwaa` | `chưaa` | ưâ impossible: a stays a letter (REG-13) |
| W145 | Escape by doubling | Telex | trad | - | `cuaa` | `cuaa` | c + uâ impossible: a stays a letter (REG-13) |
| W146 | Escape by doubling | Telex | trad | - | `khoaa` | `khoaa` | oâ impossible |
| W147 | Escape by doubling | Telex | trad | - | `boss` | `bos` | boundary restores boss (lexicon) |
| W148 | Escape by doubling | Telex | trad | - | `traffic` | `trafic` | boundary restores traffic (REG-27) |
| W149 | Escape by doubling | Telex | trad | - | `wfa` | `ừa` |  |
| W150 | Escape by doubling | Telex | trad | - | `wfaaa` | `ừaaa` | stretching keeps the tone where it was (REG-13) |
| W151 | Tone removal | Telex | trad | - | `asz` | `a` | z removes the tone |
| W152 | Tone removal | Telex | trad | - | `aszz` | `az` | second z has nothing to remove: literal |
| W153 | Tone removal | Telex | trad | - | `quz` | `quz` | no nucleus: z is literal, no crash |
| W154 | Tone removal | Telex | trad | - | `QUZ` | `QUZ` | no crash |
| W155 | Tone removal | Telex | trad | - | `qutz` | `qutz` | no crash |
| W156 | Tone removal | Telex | trad | - | `za` | `za` | z with no tone to remove is a letter (REG-25) |
| W157 | Tone removal | Telex | trad | - | `zas` | `zá` | teencode z onset (Tier B) |
| W158 | Tone removal | Telex | trad | - | `vieejtz` | `viêt` |  |
| W158a | Tone removal | Telex | trad | - | `daausz` | `dâu` | z removes the tone (ENG-R411) |
| W158b | Tone removal | Telex | trad | - | `daauszz` | `dau` | a second z removes the marks (REG-34) |
| W158c | Tone removal | Telex | trad | - | `daauszzz` | `dauz` | nothing left to remove: a letter |
| W158d | Tone removal | Telex | trad | - | `dduwowngfzz` | `duong` | every mark at once, `đ` becomes `d` |
| W158e | Tone removal | Telex | trad | - | `aaz` | `a` | no tone: z removes the circumflex |
| W158f | Tone removal | Telex | trad | - | `aaza` | `â` | after a removal the modifier key marks again |
| W158g | Tone removal | Telex | trad | - | `aazaa` | `aa` | and its second press escapes |
| W158h | Tone removal | Telex | trad | - | `daauszza` | `dâu` | the circumflex comes back on `a` |
| W158i | Tone removal | Telex | trad | - | `ddz` | `d` | the stroke is a mark too |
| W158j | Tone removal | Telex | trad | - | `wz` | `u` | the `ư` of a standalone `w` loses its horn |
| W159 | VNI | VNI | trad | - | `a1` | `á` |  |
| W160 | VNI | VNI | trad | - | `a2` | `à` |  |
| W161 | VNI | VNI | trad | - | `a3` | `ả` |  |
| W162 | VNI | VNI | trad | - | `a4` | `ã` |  |
| W163 | VNI | VNI | trad | - | `a5` | `ạ` |  |
| W164 | VNI | VNI | trad | - | `a6` | `â` |  |
| W165 | VNI | VNI | trad | - | `a8` | `ă` |  |
| W166 | VNI | VNI | trad | - | `o7` | `ơ` |  |
| W167 | VNI | VNI | trad | - | `u7` | `ư` |  |
| W168 | VNI | VNI | trad | - | `d9` | `đ` |  |
| W169 | VNI | VNI | trad | - | `vie65t` | `việt` |  |
| W170 | VNI | VNI | trad | - | `vie6t5` | `việt` | tone after coda |
| W171 | VNI | VNI | trad | - | `tieng61` | `tiếng` | (REG-09) |
| W172 | VNI | VNI | trad | - | `nhieu62` | `nhiều` | (REG-09) |
| W173 | VNI | VNI | trad | - | `nua73` | `nửa` | (REG-09) |
| W174 | VNI | VNI | trad | - | `duoc795` | `được` | 7 on uo horns both; 9 after the rhyme |
| W175 | VNI | VNI | trad | - | `d9uo7c5` | `được` |  |
| W176 | VNI | VNI | trad | - | `truong72` | `trường` |  |
| W177 | VNI | VNI | trad | - | `mot65` | `một` |  |
| W178 | VNI | VNI | trad | - | `hoa2` | `hòa` |  |
| W179 | VNI | VNI | modern | - | `hoa2` | `hoà` |  |
| W180 | VNI | VNI | trad | - | `a11` | `a1` | escape: literal digit |
| W181 | VNI | VNI | trad | - | `a66` | `a6` |  |
| W182 | VNI | VNI | trad | - | `d99` | `d9` | escape of đ |
| W183 | VNI | VNI | trad | - | `qu0` | `qu0` | no nucleus: 0 is literal, no crash |
| W184 | VNI | VNI | trad | - | `a10` | `a` | 0 removes the tone |
| W184a | VNI | VNI | trad | - | `a610` | `â` | 0 removes the tone (ENG-R411) |
| W184b | VNI | VNI | trad | - | `a6100` | `a` | a second 0 removes the circumflex (REG-34) |
| W184c | VNI | VNI | trad | - | `a61000` | `a0` | nothing left to remove: literal |
| W185 | VNI | VNI | trad | - | `2024` | `2024` | no vowel: digits are literal |
| W186 | VNI | VNI | trad | - | `b2` | `b2` | no vowel: literal digit, token goes literal |
| W187 | VNI | VNI | trad | - | `u7a4` | `ữa` |  |
| W188 | VNI | VNI | trad | - | `gio61ng` | `giống` |  |
| W189 | VNI | VNI | trad | - | `quy1` | `quý` |  |
| W190 | VNI | VNI | trad | - | `ca6u2` | `cầu` |  |
| W191 | VNI | VNI | trad | - | `kho6ng` | `không` |  |
| W192 | VNI | VNI | trad | - | `huo7` | `hươ` |  |
| W193 | VNI | VNI | trad | - | `Kro6ng` | `Krông` |  |
| W194 | VNI | VNI | trad | - | `gi1up` | `giúp` | relocation from i to u |
| W195 | VNI | VNI | trad | - | `ho2an` | `hoàn` |  |
| W196 | VNI | VNI | trad | - | `ho2a` | `hòa` |  |
| W197 | VNI | VNI | modern | - | `ho2a` | `hoà` |  |
| W198 | VNI | VNI | trad | - | `tie61ng` | `tiếng` |  |
| W199 | VNI | VNI | trad | - | `ddu7o7c5` | `ddu7o7c5` | Telex dd means nothing in VNI: literal |
| W200 | VNI | VNI | trad | - | `vieejt` | `vieejt` | Telex keys in VNI: never transformed |
| W201 | Case | Telex | trad | - | `Vieetj` | `Việt` |  |
| W202 | Case | Telex | trad | - | `VIEETJ` | `VIỆT` |  |
| W203 | Case | Telex | trad | - | `DDaf` | `Đà` |  |
| W204 | Case | Telex | trad | - | `Ddaf` | `Đà` |  |
| W205 | Case | Telex | trad | - | `dDaf` | `đà` | case of đ follows the first d |
| W206 | Case | Telex | trad | - | `TIEENGS` | `TIẾNG` |  |
| W207 | Case | Telex | trad | - | `TieengS` | `Tiếng` | case of a tone key is ignored |
| W208 | Case | Telex | trad | - | `W` | `Ư` |  |
| W209 | Case | Telex | trad | - | `NGUWOWIF` | `NGƯỜI` |  |
| W210 | Case | Telex | trad | - | `Aas` | `Ấ` | case of â follows the vowel letter |
| W211 | Non-viable input (before boundary) | Telex | trad | - | `text` | `tẽt` | shown while typing; boundary restores text |
| W212 | Non-viable input (before boundary) | Telex | trad | - | `user` | `ủe` | boundary restores user |
| W213 | Non-viable input (before boundary) | Telex | trad | - | `wifi` | `ừii` | boundary restores wifi |
| W214 | Non-viable input (before boundary) | Telex | trad | - | `USB` | `ÚB` | boundary restores USB |
| W215 | Non-viable input (before boundary) | Telex | trad | - | `case` | `cáe` | boundary restores case |
| W216 | Non-viable input (before boundary) | Telex | trad | - | `mother` | `mother` | th coda impossible: literal from h on (REG-03) |
| W217 | Non-viable input (before boundary) | Telex | trad | - | `keyboard` | `keyboard` | ey impossible: literal from y on (REG-03) |
| W218 | Non-viable input (before boundary) | Telex | trad | - | `startup` | `startup` | st onset impossible: literal from t on (REG-03) |
| W219 | Non-viable input (before boundary) | Telex | trad | - | `facebook` | `facebook` | f onset impossible: literal from the first key |
| W220 | Non-viable input (before boundary) | Telex | trad | - | `java` | `java` | j onset impossible |
| W221 | Non-viable input (before boundary) | Telex | trad | - | `password` | `pasword` | literal after the escape, no second mark (REG-19); boundary restores |
| W222 | Non-viable input (before boundary) | Telex | trad | - | `verbose` | `vẻbose` | b impossible after vẻ: literal; boundary restores (REG-18) |
| W223 | Non-viable input (before boundary) | Telex | trad | - | `qw` | `qw` | qư impossible: w is a letter (REG-20) |
| W224 | Non-viable input (before boundary) | Telex | trad | - | `qww` | `qww` |  |
| W225 | Non-viable input (before boundary) | Telex | trad | - | `year` | `year` | yea impossible before the tone key arrives (REG-03) |
| W226 | Names and loanwords | Telex | trad | - | `Kroong` | `Krông` | Tier B cluster kr |
| W227 | Names and loanwords | Telex | trad | - | `DDawsk` | `Đắk` | Tier B coda k |
| W228 | Names and loanwords | Telex | trad | - | `Lawsk` | `Lắk` |  |
| W229 | Names and loanwords | Telex | trad | - | `Pawsc` | `Pắc` | p onset |
| W230 | Names and loanwords | Telex | trad | - | `Thuootj` | `Thuột` | Buôn Ma Thuột |
| W231 | Names and loanwords | Telex | trad | - | `Buoon` | `Buôn` |  |
| W232 | Names and loanwords | Telex | trad | - | `pias` | `pía` | bánh pía (REG-08) |
| W233 | Names and loanwords | Telex | trad | - | `buyts` | `buýt` | labial + medial: Tier B loan (xe buýt) |
| W234 | Names and loanwords | Telex | trad | - | `quowrn` | `quởn` | Tier B qu + ơn |
| W235 | Names and loanwords | Telex | trad | - | `huow` | `hươ` | becomes huơ at the boundary |
| W236 | Backspace inside a token | Telex | trad | - | `vieejt⌫` | `việ` | ⌫ = Backspace |
| W237 | Backspace inside a token | Telex | trad | - | `vieejt⌫⌫` | `vi` | deleting ệ takes its tone with it |
| W238 | Backspace inside a token | Telex | trad | - | `hoaf⌫` | `hò` | tone was on o: stays |
| W239 | Backspace inside a token | Telex | modern | - | `hoaf⌫` | `ho` | tone was on à: removed with it |
| W240 | Backspace inside a token | Telex | trad | - | `hoafn⌫` | `hòa` | tone relocates after the coda is deleted |
| W241 | Backspace inside a token | Telex | trad | - | `nhaamff⌫` | `nhâm` | the escape letter goes with the tone key it undid (ENG-R711) |
| W242 | Backspace inside a token | Telex | trad | - | `ass⌫` | `a` | the escape letter goes with the tone key it undid |
| W242a | Backspace inside a token | Telex | trad | - | `nhaamff⌫f` | `nhầm` | the tone can be applied again (REG-24) |
| W242b | Backspace inside a token | Telex | trad | - | `boss⌫` | `bo` | one key too many costs one character |
| W242c | Backspace inside a token | Telex | trad | - | `boss⌫s` | `bó` | the escape is gone, so `s` is a tone key again (ENG-R441) |
| W242d | Backspace inside a token | Telex | trad | - | `cass⌫o` | `cao` |  |
| W242e | Backspace inside a token | Telex | trad | - | `teee⌫e` | `tê` | the circumflex key went with the escape letter |
| W242f | Backspace inside a token | Telex | trad | - | `teee⌫epj` | `tệp` |  |
| W242g | Backspace inside a token | Telex | trad | - | `verr⌫` | `ve` |  |
| W242h | Backspace inside a token | Telex | trad | - | `Saff⌫` | `Sa` |  |
| W242i | Backspace inside a token | Telex | trad | - | `Quyeenff⌫` | `Quyên` |  |
| W242j | Backspace inside a token | Telex | trad | - | `ww⌫` | `` | the escape removed the standalone `ư`: both keys go |
| W242k | Backspace inside a token | Telex | trad | - | `WSw⌫` | `` | the `S` lost its vowel to the escape (ENG-R432): it goes too |
| W242l | Backspace inside a token | Telex | trad | - | `booo⌫` | `bo` | an escape letter that stays a letter (`oo`) |
| W242m | Backspace inside a token | VNI | trad | - | `a11⌫` | `a` |  |
| W242n | Backspace inside a token | Telex | trad | - | `daauszz⌫` | `da` | after a mark removal Backspace takes one character (ENG-T38) |
| W242o | Backspace inside a token | Telex | trad | - | `aaz⌫` | `` | the `z` has nothing left to remove: it goes too |
| W242p | Backspace inside a token | Telex | trad | - | `wsaw⌫` | `á` | the `s` waited for a vowel and lands on the `a` (ENG-R432) |
| W242q | Backspace inside a token | Telex | trad | - | `wsoww⌫` | `ó` |  |
| W242r | Backspace inside a token | Telex | trad | - | `wszaw⌫` | `a` | the whole tone chain waits, the removal included |
| W242s | Backspace inside a token | Telex | trad | - | `wzow⌫` | `ư` | after a mark removal only the later `w` gives the horn (ENG-R710) |
| W242t | Backspace inside a token | VNI | trad | - | `u70o7⌫` | `ư` |  |
| W242u | Backspace inside a token | Telex | trad | - | `dwndw⌫` | `đn` | retyped from the letters shown (ENG-R711 fallback 2) |
| W242v | Backspace inside a token | Telex | trad | - | `dwnsdw⌫` | `đn` | retyped without the tone key: its vowel went with the escape |
| W242w | Backspace inside a token | Telex | trad | - | `dwngsdw⌫` | `đng` | the same with the coda `ng` |
| W243 | Backspace inside a token | Telex | trad | - | `duwowngf⌫⌫⌫` | `dư` | ơ deleted with its horn and tone; ư keeps its horn |
| W243a | Backspace inside a token | Telex | trad | - | `thuowr⌫` | `thư` | one `w` marked `ư` and `ơ`: it stays with `ư` (ENG-R710) |
| W243b | Backspace inside a token | Telex | trad | - | `dduowcj⌫⌫` | `đư` | the tone goes with `ợ`, the shared `w` stays |
| W243c | Backspace inside a token | Telex | trad | - | `truowngf⌫⌫⌫` | `trư` | coda, then `ờ`; `ư` keeps its horn |
| W243d | Backspace inside a token | Telex | trad | - | `thuwor⌫` | `thư` | `uwo` order: the `o` showed its horn by completion (ENG-R530) |
| W243e | Backspace inside a token | Telex | trad | - | `thuwowr⌫` | `thư` | explicit `uwow`: the second `w` goes, the first keeps `ư` |
| W243f | Backspace inside a token | VNI | trad | - | `thuo73⌫` | `thư` | one `7` marked `ư` and `ơ`: it stays with `ư` |
| W243g | Backspace inside a token | Telex | trad | - | `THUOWR⌫` | `THƯ` | uppercase |
| W243h | Backspace inside a token | Telex | trad | - | `nguowif ⌫⌫⌫` | `ngư` | the first Backspace re-opens the word (ENG-R1002, ENG-R1003) |
| W243i | Backspace inside a token | Telex | trad | - | `thuowr ⌫⌫` | `thu` | re-opened `thuở` shows the commit spelling `uơ` (ENG-R532): its `u` keeps no horn |
| W243j | Backspace inside a token | Telex | trad | - | `cuowios⌫⌫` | `cu` | `ô` replaced the horns (ENG-R533): the `u` shows none and stays plain |
| W243k | Backspace inside a token | Telex | trad | - | `tiesng ⌫⌫⌫⌫⌫eesn` | `tiến` | the restore of the re-opened word ends at `tie` (ENG-R1005, REG-33) |
| W243l | Backspace inside a token | Telex | trad | - | `baas ⌫⌫⌫⌫aasm` | `bấm` | the restore ends at `ba` |
| W243m | Backspace inside a token | Telex | trad | - | `huux ⌫⌫w` | `hưu` | the restore ends at `huu` |
| W243n | Backspace inside a token | Telex | trad | - | `text ⌫⌫⌫x` | `tẽ` | the restore ends at `te` |
| W243o | Backspace inside a token | VNI | trad | - | `tie1ng ⌫⌫⌫⌫⌫e61ng` | `tiếng` |  |
| W244 | Options | Telex | trad | bracket keys on | `[` | `ơ` | bracket option on |
| W245 | Options | Telex | trad | bracket keys on | `]` | `ư` | bracket option on |
| W246 | Options | Telex | trad | standalone w off | `w` | `w` | standalone w off |
| W247 | Options | Telex | trad | standalone w off | `tw` | `tw` | standalone w off |
| W248 | Options | Telex | trad | standalone w off | `tuw` | `tư` | w as a modifier still works |
| W249 | Slang and rare words | Telex | trad | - | `dzoo` | `dzô` | `dz` onset, Tier B (REG-28) |
| W250 | Slang and rare words | Telex | trad | - | `dzaayj` | `dzậy` | tone on the first letter of `ây` |
| W251 | Slang and rare words | Telex | trad | - | `Dzui` | `Dzui` | capital `D`, no marks |
| W252 | Slang and rare words | VNI | trad | - | `dzo6` | `dzô` | `dz` onset in VNI |
| W253 | Slang and rare words | Telex | trad | - | `heoj` | `hẹo` | absent from common dictionaries, valid Tier A `eo` + nặng (REG-29) |

Rows W249-W253 were added from the product owner's P0 list after the reference-model run; add them to the oracle before relying on them.

### 13.9 Worked examples: commit decisions (76 rows, plus 13.9.1 to 13.9.5)

Each row types the keys, then a space. Fixture data for this table only: the English lexicon contains `test this these there best max list been text user wifi usb case password traffic boss coffee as is was has its us car did theme does door her post says war two wow ask task zoom more year mother keyboard verbose startup data plans grows www less tomorrow the and you a i cost room tar class app file think tricky`; the tech-always list contains `www wifi usb`; the code-only list contains `tar sudo chown`; the capitalized code-word list is empty; every Tier A syllable is attested except `dóe hẻ dổ pót sáy ửa tơn dơn`; the ambiguity table is the proposal in ENG-R821. "Previous token" is the language of the run (8.3): a seed token typed before the keys, `vieejt` (`vie65t` in VNI) for `vi` and `and` for `en`. Rows B035a to B035i were added on 15/11/2026 with the product owner's report and its review (REG-35, ENG-R850), rows B035j to B035n on 16/11/2026 with the product owner's retest and rule (REG-36, RV5 of ENG-R828, the sentence condition of L9 in ENG-R850), rows B035o to B035t on 18/11/2026 with the product owner's decision that L9 decides before L6 and L7 for code-only words (REG-38, ENG-R850; `chown` joined the fixture code-only list for them), and rows B052a to B052d the same day with the product owner's answer to Q9 (rule L4a, REG-39). When their keys hold several tokens, the row types them from an empty field, the committed text is the whole line and the rule column names the rule that decided the last token. With D29 off (`lineStartRevision`, ENG-R829) B035j still gives `Tả thử`, because `Tar` is decided at its own commit, while B035n gives `TAR thử`.

| # | Keys typed, then Space | Method | Previous token | App context | Committed text | Rule that decided |
|---|---|---|---|---|---|---|
| B001 | `text` | Telex | none | general | `text` | L5 invalid: restore |
| B002 | `user` | Telex | none | general | `user` | L5 invalid: restore |
| B003 | `wifi` | Telex | none | general | `wifi` | L5 invalid: restore |
| B004 | `USB` | Telex | none | general | `USB` | L5 invalid: restore |
| B005 | `case` | Telex | none | general | `case` | L5 invalid: restore |
| B006 | `data` | Telex | none | general | `data` | L5 invalid: restore |
| B007 | `verbose` | Telex | none | general | `verbose` | L5 invalid: restore |
| B008 | `password` | Telex | none | general | `password` | L4 escape, raw is English: restore |
| B009 | `traffic` | Telex | none | general | `traffic` | L4 escape, raw is English: restore |
| B010 | `boss` | Telex | none | general | `boss` | L4 escape, raw is English: restore |
| B011 | `coffee` | Telex | none | general | `coffee` | L4 escape, raw is English: restore |
| B012 | `less` | Telex | none | general | `less` | L4 escape, raw is English: restore |
| B013 | `tomorrow` | Telex | none | general | `tomorrow` | L4 escape, raw is English: restore |
| B014 | `ass` | Telex | none | general | `as` | L4 escape, escaped form is English: keep |
| B015 | `ddid` | Telex | none | general | `did` | L4 escape, escaped form is English: keep |
| B016 | `uww` | Telex | none | general | `uw` | L4 escape: keep |
| B017 | `plans` | Telex | none | general | `plans` | L6 extended only, raw is English: restore |
| B018 | `grows` | Telex | none | general | `grows` | L6 extended only, raw is English: restore |
| B019 | `ask` | Telex | none | general | `ask` | L6 extended only, raw is English: restore |
| B020 | `zoom` | Telex | none | general | `zoom` | L6 extended only, raw is English: restore |
| B021 | `two` | Telex | none | general | `two` | L6 extended only, raw is English: restore |
| B022 | `wow` | Telex | none | general | `wow` | L6 extended only, raw is English: restore |
| B023 | `does` | Telex | none | general | `does` | L8 not attested, raw is English: restore |
| B024 | `test` | Telex | none | general | `test` | L11 ambiguity row = en: restore |
| B025 | `test` | Telex | vi | general | `test` | L11 ambiguity row = en: restore |
| B026 | `tets` | Telex | none | general | `tét` | L7 raw not English: keep |
| B027 | `this` | Telex | none | general | `thí` | L11 ambiguity row = vi: keep |
| B028 | `this` | Telex | en | general | `this` | L10 English run: restore |
| B029 | `car` | Telex | vi | general | `cả` | L11 ambiguity row = vi: keep |
| B030 | `car` | Telex | en | general | `car` | L10 English run: restore |
| B031 | `is` | Telex | vi | general | `is` | L11 ambiguity row = en: restore |
| B032 | `as` | Telex | vi | general | `á` | L11 ambiguity row = vi: keep |
| B033 | `did` | Telex | vi | general | `đi` | L11 ambiguity row = vi: keep |
| B034 | `tar` | Telex | vi | general | `tả` | L11 no row, default vi: keep |
| B035 | `tar` | Telex | none | code | `tar` | L9 code context, code-only tech word at the start of a line: restore |
| B035a | `tar` | Telex | vi | code | `tả` | L11 no row, default vi (in Vietnamese text L9 does not apply): keep |
| B035b | `tar` | Telex | en | code | `tar` | L9 code context, code-only tech word after an English word: restore |
| B035c | `chinhs tar` | Telex | none | code | `chính tả` | L11 no row, default vi (after a Vietnamese word L9 does not apply): keep |
| B035d | `moo tar` | Telex | none | code | `mô tả` | L11 no row, default vi (after a Vietnamese word L9 does not apply): keep |
| B035e | `sudo tar` | Telex | none | code | `sudo tar` | L9 code context, code-only tech word after a code word: restore |
| B035f | `ta3` | VNI | vi | code | `tả` | L7 raw not English: keep |
| B035g | `mo6 ta3` | VNI | none | code | `mô tả` | L7 raw not English: keep |
| B035h | `tar` | VNI | none | code | `tar` | L0 output equals the keys typed: nothing to decide |
| B035i | `anh.tar` | Telex | none | code | `anh.tar` | L9 code context, code-only tech word joined to the previous word with no space: restore |
| B035j | `Tar thuwr` | Telex | none | code | `Tả thử` | L7 raw not English (`Tar` starts a sentence, so the rules after L9 kept it at its own commit, ENG-R850): keep |
| B035k | `tar xf` | Telex | none | code | `tar xf` | L0 output equals the keys typed (`xf` is not Vietnamese, so RV5 leaves `tar`): nothing to decide |
| B035l | `tar nhaatj-kys` | Telex | none | code | `tar nhật-ký` | L7 raw not English (`-` ends `nhật`, a file name character, so RV5 leaves `tar`): keep |
| B035m | `Tar` | Telex | none | code | `Tả` | L11 no row, default vi (in sentence case at the line start and committed by a space, the word starts a sentence and L9 does not apply, ENG-R850): keep |
| B035n | `TAR thuwr` | Telex | none | code | `TẢ thử` | L7 raw not English (then RV5 revises `TAR`, restored by L9 at the line start because all caps is not sentence case, ENG-R828): keep |
| B035o | `chown` | Telex | none | code | `chown` | L9 code context, code-only tech word at the start of a line, decided before L6 and L7 although its keys are not English: restore |
| B035p | `sudo chown` | Telex | none | code | `sudo chown` | L9 code context, code-only tech word after a code word: restore |
| B035q | `chown` | Telex | vi | code | `chơn` | L7 raw not English (in Vietnamese text L9 does not apply): keep |
| B035r | `chown` | Telex | none | general | `chơn` | L7 raw not English: keep |
| B035s | `Chown` | Telex | none | code | `Chơn` | L7 raw not English (in sentence case at the line start and committed by a space, the word starts a sentence and L9 does not apply, ENG-R850): keep |
| B035t | `chown thuwr` | Telex | none | code | `chơn thử` | L7 raw not English (then RV5 revises `chown`, restored by L9 at the line start, ENG-R828): keep |
| B036 | `Kroong` | Telex | none | general | `Krông` | L6 extended, raw not English: keep |
| B037 | `DDawsk` | Telex | none | general | `Đắk` | L6 extended, raw not English: keep |
| B038 | `Pawsc` | Telex | none | general | `Pắc` | L7 raw not English: keep |
| B039 | `Thuootj` | Telex | none | general | `Thuột` | L7 raw not English: keep |
| B040 | `ddc` | Telex | none | general | `đc` | L3 no vowel: keep |
| B041 | `DDL` | Telex | none | general | `ĐL` | L3 no vowel: keep |
| B042 | `thuowr` | Telex | none | general | `thuở` | L7 raw not English: keep |
| B043 | `huow` | Telex | none | general | `huơ` | L7 raw not English: keep |
| B044 | `nghaxi` | Telex | none | general | `nghaxi` | L0 output equals the keys typed: nothing to decide |
| B045 | `nghoo` | Telex | none | general | `nghoo` | L0 output equals the keys typed: nothing to decide |
| B046 | `hok` | Telex | none | general | `hok` | L0 output equals the keys typed: nothing to decide |
| B047 | `ba6c3` | VNI | none | general | `ba6c3` | L5 invalid: restore |
| B048 | `vie65t` | VNI | none | general | `việt` | L7 raw not English: keep |
| B049 | `a1` | VNI | vi | general | `á` | L7 raw not English: keep |
| B050 | `year` | Telex | none | general | `year` | L0 output equals the keys typed: nothing to decide |
| B051 | `mother` | Telex | none | general | `mother` | L0 output equals the keys typed: nothing to decide |
| B052 | `baans` | Telex | none | general | `bấn` | L7 raw not English: keep |
| B052a | `dduwowngfzz` | Telex | none | general | `duong` | L4a tone removal, raw not English: keep |
| B052b | `vieejtz` | Telex | none | general | `viêt` | L4a tone removal, raw not English: keep |
| B052c | `daauszz` | Telex | none | general | `dau` | L4a tone removal, raw not English: keep |
| B052d | `vie65t0` | VNI | none | general | `viêt` | L4a tone removal, raw not English: keep |

#### 13.9.1 Commit at every boundary key (P0-3)

Same fixtures as 13.9. The decision at commit MUST NOT depend on which boundary key ends the token, except where a rule names the key (L9a, ENG-R825; the space of the sentence condition of L9, ENG-R850; RV5, ENG-R828): every key classed as a boundary in section 9 (whitespace, every ASCII punctuation or symbol, Return, Tab) runs the same commit as Space, and the boundary key reaches the app after the edit (`thenPassThrough`), so the text is in the right order. For Return, the edit is applied before Return is delivered, so a chat app never sends the unrestored text.

| # | Keys typed | Boundary key | Method | Previous token | App context | Text after the boundary | Rule that decided |
|---|---|---|---|---|---|---|---|
| B053 | `dzaayj` | Space | Telex | none | general | `dzậy ` | L6 extended, raw not English: keep |
| B054 | `dzoo` | `,` | Telex | none | general | `dzô,` | L6 extended, raw not English: keep |
| B055 | `heoj` | Space | Telex | none | general | `hẹo ` | raw not English: keep (ENG-R316) |
| B056 | `heoj` | `,` | Telex | none | general | `hẹo,` | same as B055 |
| B057 | `text` | `,` | Telex | none | general | `text,` | L5 invalid: restore |
| B058 | `text` | `.` | Telex | none | general | `text.` | L5 invalid: restore |
| B059 | `user` | `;` | Telex | none | general | `user;` | L5 invalid: restore |
| B060 | `wifi` | `?` | Telex | none | general | `wifi?` | L5 invalid: restore |
| B061 | `case` | `!` | Telex | none | general | `case!` | L5 invalid: restore |
| B062 | `USB` | `)` | Telex | none | general | `USB)` | L5 invalid: restore |
| B063 | `text` | `:` | Telex | none | general | `text:` | L5 invalid: restore |
| B064 | `text` | Return | Telex | none | general | `text` then a new line | L5 invalid: restore, then Return is delivered |
| B064a | `Suwar looxi chinhs tar` | `"` | Telex | none | code | `Sửa lỗi chính tả"` | L11 no row, default vi (after a Vietnamese word L9 does not apply): keep |
| B064b | `tar` | `"` | Telex | none | code | `tar"` | L9 code context, code-only tech word at the start of a line: restore |
| B064c | `Tar` | `-` | Telex | none | code | `Tar-` | L9 code context, code-only tech word at the start of a line in sentence case, committed by a key that is not a space: restore |

Rows B053-B064 were added from the product owner's P0 list after the reference-model run; add them to the oracle before relying on them. Rows B064a and B064b (REG-35, 15/11/2026) type the product owner's terminal message: the quote that ends the word is a boundary key like any other, so it changes nothing; only what comes before the word decides L9 (ENG-R850). `spec/reference-model/boundary.py` checks them with rows B035 to B035e, B035i to B035t and B064c. Rows B035m, B035n and B064c are the exceptions to the text column at other boundary keys. A word in sentence case at the start of a line is decided by the rules after L9 only when a space commits it (ENG-R850): `Tar` and a space give `Tả ` (B035m), `Tar` and any other key give the keys and that key (B064c, `Tar-`). RV5 (ENG-R828) revises `TAR` (B035n) only when the key that commits `thử` is a space, Return, `,`, `!` or `?` (`TAR thử.` and `TAR thử-` keep `TAR`); the decision of `thử` itself is the same at every key. Row B035j holds at every key, because the space after `Tar` is part of its keys.

#### 13.9.2 English run in a sentence (ENG-R823)

Same fixtures as 13.9. Each row types the keys from an empty field, so every token before the last one is part of the run, and ends with the boundary key; the rule column names the rule that decided the last token. Rows B065-B072 were added with the product owner's report of 14/11/2026 (REG-32); `spec/reference-model/boundary.py` checks them. The 13.9 fixtures have no collision lists (8.2), so rules L9a, L9b and the revisions of ENG-R828 never apply in these rows; 13.9.3 shows them with the bundled lists.

| # | Keys typed | Boundary key | Method | Previous token | App context | Text after the boundary | Rule that decided |
|---|---|---|---|---|---|---|---|
| B065 | `Khusc caif cacs app caafn thieest treen win cungx tricky as` | `.` | Telex | none | general | `Khúc cài các app cần thiết trên win cũng tricky á.` | L11 ambiguity row = vi: keep |
| B066 | `dduwowcj as` | `.` | Telex | none | general | `được á.` | L11 ambiguity row = vi: keep |
| B067 | `treen server been` | Space | Telex | none | general | `trên server bên ` | L11 ambiguity row = vi: keep |
| B068 | `guwir file car` | Space | Telex | none | general | `gửi file cả ` | L11 ambiguity row = vi: keep |
| B069 | `this is the best car` | Space | Telex | none | general | `thí is the best car ` | L10 English run: restore |
| B070 | `I think this is as good as` | Space | Telex | none | general | `I think this is as good as ` | L10 English run: restore |
| B071 | `This is as` | Space | Telex | none | general | `Thí is as ` | L10 English run: restore |
| B072 | `tricky as` | Space | Telex | none | general | `tricky as ` | L10 English run: restore |

#### 13.9.3 Collision decisions in a sentence (ENG-R825 to ENG-R828)

The bundled data (8.2), Telex with default options, `lookaheadRevision` on. Each row types the keys from an empty field, then Return; the text column is the field before the new line. The last column names the rules that decided the collision words (L9a, L9b, L10, L11) and every revision (RV1 to RV4, ENG-R828); a row names a revision rule exactly when the engine revises. Rows C025 to C032 are the product owner's eight sentences (PA01 to PA08 of the W11 corpus); C033 and C034 are known costs of the RV4 guards. `CollisionWorkedExampleTests` (VietnameseEngineDataTests) replays this table. RV5 belongs to the code context and is shown in 13.9.4.

| # | Keys typed, then Return | Text before the new line | What decided |
|---|---|---|---|
| C001 | `tricky as.` | `tricky á.` | L9a keeps `as` before `.` |
| C002 | `This is as.` | `This is á.` | L9a for `as`; L9b restores `is` (`this is`) and RV1 revises `This` |
| C003 | `Yes she has.` | `Yes she has.` | L10: `has` is not a boundary particle |
| C004 | `Yes he did.` | `Yes he did.` | L10: `did` is not a boundary particle |
| C005 | `such as this` | `such as this` | L9b restores `as` (`such as`), L10 restores `this` |
| C006 | `It has been a while` | `It has been a while` | L9b restores `has` and `been` (`has been`) |
| C007 | `Me too` | `Me too` | L9b restores `too` (`me too`) |
| C008 | `Call me as soon as possible` | `Call me as soon as possible` | L10 restores the first `as`, L9b the second (`as soon as`) |
| C009 | `The car is here` | `The car is here` | L10: the English-lean `The` makes the run English (ENG-R823) |
| C010 | `Great job car nhoms` | `Great job cả nhóm` | RV4 revises `car` |
| C011 | `Deploy done sex baos` | `Deploy done sẽ báo` | RV4 revises `sex` |
| C012 | `Thanks everyone been minhf` | `Thanks everyone bên mình` | RV4 revises `been` |
| C013 | `Happy new year car nhaf` | `Happy new year cả nhà` | RV4 revises `car` |
| C014 | `If you caanf quyeenf admin` | `If you cần quyền admin` | RV3 revises `If` |
| C015 | `Reset your password` | `Reset your password` | RV3 revises `Reset` |
| C016 | `I parked the car rooif` | `I parked the car rồi` | L10 for `car`; tail word `rồi` and pre-guard `the` |
| C017 | `Love the new theme quas` | `Love the new theme quá` | L10 for `theme`; tail word `quá` |
| C018 | `Have you been owr DDaf Latj chuwa` | `Have you been ở Đà Lạt chưa` | L10 for `been`; pre-guard `you` |
| C019 | `Did you see the car hoom qua` | `Did you see the car hôm qua` | RV1 revises `Did` (`did you`); `car` stays (pre-guard `the`) |
| C020 | `Ngon as but mawsc` | `Ngon á but mắc` | L11 for `as`; a particle reading is never restored before an English word |
| C021 | `Nos ddepj as and rer` | `Nó đẹp á and rẻ` | L11 for `as`; particle reading |
| C022 | `Hay as or not` | `Hay á or not` | L11 for `as`; particle reading |
| C023 | `Is anyone there khoong` | `Is anyone there không` | L10 for `there`; tail word `không` |
| C024 | `Heets as of course` | `Hết á of course` | RV1 revises `of` (`of course`); `as` stays because `as of` is not a phrase (product owner, 15/11/2026) |
| C025 | `Khucs caif cacs app caanf thieets treen win cungx tricky as.` | `Khúc cài các app cần thiết trên win cũng tricky á.` | L9a keeps `as` before `.` |
| C026 | `Cais nayf nos tricky as. Caanf phair lamf caanr thaanj` | `Cái này nó tricky á. Cần phải làm cẩn thận` | L9a keeps `as` before `.` |
| C027 | `Cais nayf nos tricky as hell` | `Cái này nó tricky as hell` | RV1 revises `as` (`as hell`) |
| C028 | `tricky as nha` | `tricky á nha` | RV2 revises `as` |
| C029 | `treen server been kia` | `trên server bên kia` | L11 keeps `been`: no English run (ENG-R823) |
| C030 | `Minhf nghix this is as good` | `Mình nghĩ this is as good` | L9b restores `is`; RV1 revises `this` (`this is`) and `as` (`as good`) |
| C031 | `I think this is as good as it gets` | `I think this is as good as it gets` | L10 restores `this` and both `as`; L9b restores `is` |
| C032 | `dduwowcj as.` | `được á.` | L9a keeps `as` before `.` |
| C033 | `Thank you been minhf` | `Thank you been mình` | L10 for `been`; pre-guard `you` (known cost) |
| C034 | `Welcome back car team` | `Welcome back car team` | L10 for `car`; the next word is English (known cost) |
| C035 | `tricky tows` | `tricky tớ` | L11: `tows` is a `run: vi` row (ENG-R827) |
| C036 | `such as.` | `such as.` | L9b restores `as` (`such as`): a token that continues a phrase is not a boundary particle (ENG-R825) |

#### 13.9.4 Code-only words at the start of a line (ENG-R850, RV5)

The bundled data (8.2), Telex, the code context with `lookaheadRevision` off as the rules of terminals and code editors set it (PLT-R357) and D29 on (`lineStartRevision`, ENG-R829); the rows give the same text with `lookaheadRevision` on. Each row types the keys from an empty field, then Return; the text column is the field before the new line. The last column names L9 when it restored the first word, says that L9 does not apply when the sentence condition of ENG-R850 held, and names RV5 exactly when the engine revises. With D29 off every row that names RV5 keeps the first word as typed (`tar thuwr` gives `tar thử`) and every other row gives the same text (`Tar thuwr` gives `Tả thử`). Rows K01 to K12 were added with the product owner's retest of 16/11/2026 (REG-36), rows K13 to K16 with its review, and rows K17 to K20 with the product owner's rule of the same day (a word in sentence case at a line start, ENG-R850), which rewrote K01, K04 and K13 to K16, rows K21 to K25 with its review (spaces and the openers of prose before the first word), and rows K26 to K32 with the product owner's decision of 18/11/2026 that L9 decides before L6 and L7 for code-only words (REG-38); `LineStartRevisionRealDataTests` (VietnameseEngineDataTests) replays this table.

| # | Keys typed, then Return | Text before the new line | What decided |
|---|---|---|---|
| K01 | `Tar thuwr cais nayf` | `Tả thử cái này` | L9 does not apply to `Tar`: in sentence case at the line start, committed by a space (REG-36) |
| K02 | `tee chaan quas` | `tê chân quá` | L9 restores `tee`; RV5 revises it |
| K03 | `Host mowis chayj nhanh` | `Hót mới chạy nhanh` | L9 restores `Host`, a capitalized code word; RV5 revises it, as `general` decides (known cost, W11 corpus CS0571) |
| K04 | `tar thuwr` | `tả thử` | L9 restores `tar`; RV5 revises it at Return |
| K05 | `tar -xzf a.tgz` | `tar -xzf a.tgz` | L9 restores `tar`; `-` follows it, not one space |
| K06 | `tar xf banr.tar` | `tar xf bản.tar` | L9 restores `tar`; `xf` is not Vietnamese |
| K07 | `tee nhaatj-kys.log` | `tee nhật-ký.log` | L9 restores `tee`; `-` ends `nhật`, a file name |
| K08 | `tee nhaatj.log` | `tee nhật.log` | L9 restores `tee`; `.` ends `nhật`, a file name |
| K09 | `sudo tar thuwr` | `sudo tar thử` | L9 restores `tar` after a code word: not at the line start |
| K10 | `host google.com` | `host google.com` | L9 restores `host`; `google` is not Vietnamese |
| K11 | `host minh` | `host minh` | L9 restores `host`; a syllable typed unchanged is not RV5 evidence (a host name) |
| K12 | `tar` | `tar` | L9 restores `tar`; a one-word line (known cost) |
| K13 | `Tee tay quas` | `Tê tay quá` | L9 does not apply to `Tee`: in sentence case at the line start, committed by a space |
| K14 | `Tar thuwr.` | `Tả thử.` | L9 does not apply to `Tar`, so the `.` after `thử` changes nothing |
| K15 | `tar anh aasy` | `tar anh ấy` | L9 restores `tar`; `anh` typed unchanged is not RV5 evidence (known cost) |
| K16 | `Host minh` | `Host minh` | L9 restores `Host`, a capitalized code word (`~/.ssh/config`); `minh` typed unchanged is not RV5 evidence |
| K17 | `TAR thuwr` | `TẢ thử` | L9 restores `TAR`, since all caps is not sentence case; RV5 revises it |
| K18 | `Tee-Object` | `Tee-Object` | L9 restores `Tee`, since `-` commits it, not a space |
| K19 | `Host nayf` | `Hót này` | L9 restores `Host`, a capitalized code word; RV5 revises it |
| K20 | `Host github.com` | `Host github.com` | L9 restores `Host`, a capitalized code word (`~/.ssh/config`) |
| K21 | `"Tar thuwr cais nayf"` | `"Tả thử cái này"` | L9 does not apply to `Tar`: only a quote stands before it on the line |
| K22 | `- tar thuwr` | `- tả thử` | L9 restores `tar` (a list marker before it is not a word); RV5 revises it |
| K23 | `# Tee tay quas` | `# Tê tay quá` | L9 does not apply to `Tee`: only a heading or comment marker and a space stand before it |
| K24 | `    Tar thuwr` | `    Tả thử` | L9 does not apply to `Tar`: only an indent stands before it |
| K25 | `sudo Tar thuwr` | `sudo Tar thử` | L9 restores `Tar` after a code word: a word stands before it on the line |
| K26 | `chown -R minh` | `chown -R minh` | L9 restores `chown`, whose keys are not English, at the line start (REG-38) |
| K27 | `sudo chown -R minh` | `sudo chown -R minh` | L9 restores `chown` after a code word |
| K28 | `ls; chown minh` | `ls; chown minh` | L9 restores `chown`: `ls` is not a Vietnamese word |
| K29 | `ps -ef` | `ps -ef` | L9 restores `ef` (`è` in the general context) |
| K30 | `awk -F` | `awk -F` | L9 restores `awk` (`ăk` in the general context) |
| K31 | `chown thuwr` | `chơn thử` | L9 restores `chown`; RV5 revises it |
| K32 | `tay chown` | `tay chơn` | L9 does not apply to `chown`: `tay`, a Vietnamese syllable typed unchanged, stands before it |

#### 13.9.5 Escape at commit (ENG-R804, REG-37, REG-40, REG-41)

The bundled data (8.2), Telex with default options. Each row types the keys from an empty field, then a space; the text column is the field after it, and the last column names the case of ENG-R804 that decided the word with the escape. The rows give the same text in the code context with `lookaheadRevision` off, except X06, X08 and X25 to X27, which need the phrase or the English-lean word (`tủn of the light`, `the mes`, `day of`, `a mes`, `Ê có sale of`). Rows X01 to X24 were added with the product owner's report of 17/11/2026 (REG-37), rows X25 to X27 with the phrases `day off`, `a mess` and `sale off` that the product owner added on 18/11/2026, rows X28 to X39 with the product owner's report of 20/11/2026 (REG-40: a `w` doubled out of habit; X28 to X33 committed the keys with both `w` before, `wwebview` and so on, and X34 and X35 the keys with both `w` with `typoCorrection` off); all of X28 to X39 give the same text in the code context with `lookaheadRevision` off. Rows X40 to X43 were added with the product owner's decision of 22/11/2026 (REG-41: a capitalised word typed `Ww`, whose escaped letter now takes the capital of the `Ư` it removed, ENG-R903; X40 to X42 committed `wade `, `warden ` and `w ` before), and give the same text in the code context with `lookaheadRevision` off. `EscapeCommitRealDataTests` (VietnameseEngineDataTests) replays this table, and `escape-regression.txt` holds 393 more words of the sweep.

| # | Keys typed, then Space | Text after the space | What decided |
|---|---|---|---|
| X01 | `leecher` | `leecher ` | (d): no doubling, two vowel groups (`lecher`) |
| X02 | `cheeseburger` | `cheeseburger ` | (d): no doubling (`chéeburger`) |
| X03 | `coffeehouse` | `coffeehouse ` | (d): a doubling, then a second vowel group (`cofeehouse`) |
| X04 | `cookout` | `cookout ` | (d): no doubling (`cokout`) |
| X05 | `off` | `of ` | (a): a needed doubling (`of` alone commits `ò`), no English context |
| X06 | `turn off the light` | `turn off the light ` | (a): `turn off` is a phrase; RV1 restores `turn` |
| X07 | `tawts off ddi` | `tắt of đi ` | (a): the run holds a Vietnamese token |
| X08 | `the mess` | `the mess ` | (a): `the` is an English-lean word, so the run is English |
| X09 | `what a mess` | `what a mess ` | (a): the run is English |
| X10 | `mess` | `mes ` | (a): a needed doubling (`mes` alone commits `mé`) |
| X11 | `ass` | `as ` | (a): a needed doubling (`as` alone commits `á`) |
| X12 | `pass` | `pass ` | (a): not needed (`pas` alone is restored by L8) |
| X13 | `tooi pass moon` | `tôi pass môn ` | (a) for `pass`, then L11 keeps `môn` |
| X14 | `dessert` | `dessert ` | (a): not needed (`desert` shows `dểt`, restored by L5) |
| X15 | `costs` | `costs ` | (a): no doubling (the second `s` comes after `t`) |
| X16 | `tarr` | `tar ` | (b) |
| X17 | `ddid` | `did ` | (b), REG-10 |
| X18 | `password` | `password ` | (c) |
| X19 | `www` | `www ` | (c), ENG-T12 |
| X20 | `nhaamff` | `nhâmf ` | (d): a doubling, one vowel group |
| X21 | `boooong` | `booong ` | (d): a doubling, one vowel group |
| X22 | `sooocs` | `soóc ` | (d): a doubling, one vowel group |
| X23 | `Kroong Anaa` | `Krông Ana ` | (d): the doubling is the last key |
| X24 | `pajama` | `pajama ` | (d): no doubling (`pạma`) |
| X25 | `day off` | `day off ` | (a): `day off` is a phrase |
| X26 | `a mess` | `a mess ` | (a): `a mess` is a phrase |
| X27 | `Ee cos sale off` | `Ê có sale off ` | (a): `sale off` is a phrase, while the run holds Vietnamese tokens |
| X28 | `wwebview` | `webview ` | (d): a standalone `w` doubling, so `R′` is restored |
| X29 | `Wwebview` | `Webview ` | (d): `R′` keeps the case of the other keys; `C` is `Webview` too since REG-41 (ENG-R903) |
| X30 | `vieejt wwebview` | `việt webview ` | (d), after a Vietnamese word |
| X31 | `wwiki` | `wiki ` | (d) |
| X32 | `wwordpress` | `wordpress ` | (d) |
| X33 | `wwebsite` | `website ` | (d): `website` is not in the lexicon |
| X34 | `answwer` | `answer ` | (c′): `ánwer`, the `s` set the tone before the doubling |
| X35 | `softwware` | `software ` | (c′): `sòtware` |
| X36 | `dowwnload` | `dowwnload ` | (d): the doubling undid a horn, so `R` (`download` is not in the lexicon) |
| X37 | `powwow` | `powwow ` | (c): `R` English, the doubling stays |
| X38 | `wwindows` | `windows ` | (b) |
| X39 | `ww` | `w ` | (d): a deliberate form, the doubling is the last key |
| X40 | `Wwade` | `Wade ` | (b): the escaped letter takes the capital of the `Ư` it removed, so `C` is `Wade` (ENG-R903, REG-41) |
| X41 | `Wwarden` | `Warden ` | (b), REG-41 |
| X42 | `Ww` | `W ` | (d): a deliberate form, the doubling is the last key, REG-41 |
| X43 | `WWade` | `Wade ` | (b): Shift on both keys, as before |

### 13.10 Worked examples: restore toggle

| # | Events | Result |
|---|---|---|
| E01 | `vieejt`, toggle | `vieejt` (key swallowed) |
| E02 | `vieejt`, toggle, toggle | `vieejt`; the second toggle passes through (ENG-R702) |
| E02b | `vieejt`, toggle, Backspace, toggle | `việ` (Backspace shortens the restored token to `vieej`; the next toggle is not consecutive, so ENG-R701 composes it and marks it user-kept) |
| E03 | VNI `vie65t`, toggle | `vie65t` |
| E04 | `test`, space (commits `test `), Backspace, toggle | `tét` |
| E05 | `ban`, toggle | Escape passes through; text stays `ban` |
| E06 | `vieejt`, space, toggle | Escape passes through (no active token) |
| E07 | VNI `d9uo7c5`, toggle | `d9uo7c5` |
| E08 | `traffic` (shows `trafic`), toggle | `traffic` |
| E09 | `tricky`, space, `as`, space, toggle | the field shows `tricky á ` (rule L10 restored `as` because `tricky` is English, ENG-R823, and the token alone keeps `á` by its `vi` row; the toggle right after the commit puts `á` back and marks it user-kept, ENG-R706) |
| E10 | `tricky`, space, `as`, space, toggle, toggle | the field shows `tricky á `; the second toggle passes through (ENG-R702) |
| E11 | `tricky`, space, `as,`, toggle | the field shows `tricky á,` (the boundary character stays, ENG-R706; before `.`, `!`, `?` or Return the bundled data keeps `á` by rule L9a, `as` being its boundary particle, ENG-R825, so there is no restore to undo; the 13.9 fixtures have no boundary-particle list) |
| E12 | `tricky`, space, `best`, space, toggle | the field shows `tricky best `; Escape passes through (its `en` row restores `best` alone, rule L11, so the restore did not come from the words before it, ENG-R706) |
| E13 | `tricky`, space, `as`, Return, toggle | Escape passes through (Return cleared the history, ENG-R706, ENG-R829) |

### 13.11 W11 collision corpus

The W11 research (13/11 to 15/11/2026) produced a labelled corpus of 1,206 chat, office, developer and control sentences (11,180 tokens, 1,343 collision tokens: 720 meant as English, 623 as Vietnamese) and three small sets written to break the rules (57, 42 and 81 lines). They become fixtures of the `CollisionCorpusTests` target with their expected outputs under the rules of ENG-R825 to ENG-R828 (QA-R68). Measured with the engine of 15/11/2026 in host mode (Return ends the run), tone typed at the end: English-intent collisions 76.1 % (548 of 720), Vietnamese-intent 99.5 % (620 of 623), 98 revisions and none wrong, no non-collision token changed, 1,000 sentences exact; tone typed after the vowel: 76.1 % and 98.8 %, 96 revisions, none wrong; the three sets: 15, 11 and 21 revisions, none wrong. The same corpus without the collision rules (`lookaheadRevision` off) gives 58.5 % and 94.5 %. These numbers are the targets of ENG-R876. *(With rule L4 as amended by the product owner on 17/11/2026, ENG-R804, REG-37, the collision numbers are unchanged and 32 more sentences of each habit are exact (1,032 and 1,029; `pass`, `posts`, `costs`, `off`, `mess`, `Terraform`, `Grafana`, `DeepSeek` are kept as typed); without the collision rules 903 sentences are exact instead of 876. With the phrases `day off`, `sale off` and `a mess` added by the product owner on 18/11/2026 one more sentence of each habit is exact, 1,033 and 1,030: `Ê có sale off 50%` keeps `off`; the collision numbers do not move.)*

### 13.12 Worked examples: typo correction (84 rows, 1.1.0)

Section 11A, ENG-T50. The bundled data (8.2), Telex with default options unless the row says VNI, the `general` context, `typoCorrection` on, from an empty field unless the row types more. The never-correct list, the keep lists and the macro table are empty except where a row names an entry. Each row types the keys and then the key shown (a space unless the row says otherwise); the text column is the field after it. Rows S01 to S30 correct; S31 to S67 do not, one row per exclusion; S68 to S73 undo and re-open; S74 to S84 were added after the review of 18/11/2026 (S82 corrects, the others do not). The decision of 8.1 for every row (the text the 1.0 engine leaves and its reason code) was checked against the 1.0 engine with the bundled data on 18/11/2026, and again on 19/11/2026 against the engine of 1.0.1 (rules L4a and the REG-38 change of L9 included) with `typoCorrection` off, where every row kept its text and only the reason given for S46 changed; the correction side was checked against the bundled lexicon with a model of the rules; each exclusion row types a word that would be corrected but for the rule it names, unless the row says otherwise. The rows run against the engine once it exists.

| # | Keys typed, then the key shown | Text after | What decided |
|---|---|---|---|
| S01 | `androdi` | `android ` | transposition `di` -> `id`; the token was shown as typed (L0) |
| S02 | `gramar` | `grammar ` | the cluster case of ENG-R1110 (b): `grẩm` was on screen, kept by L6; a missing `m` |
| S03 | `recieve` | `receive ` | transposition |
| S04 | `whcih` | `which ` | transposition; `ưhcih` was on screen and L5 would have restored the keys |
| S05 | `becuase` | `because ` | transposition |
| S06 | `abotu` | `about ` | transposition |
| S07 | `wrold` | `world ` | transposition; restored by L5 first |
| S08 | `exapmle` | `example ` | transposition |
| S09 | `documnets` | `documents ` | transposition |
| S10 | `adress` | `address ` | a missing double |
| S11 | `tomorow` | `tomorrow ` | a missing double |
| S12 | `langage` | `language ` | an omitted letter; `lângge` was on screen (L5) |
| S13 | `libary` | `library ` | an omitted letter |
| S14 | `somthing` | `something ` | an omitted letter |
| S15 | `untill` | `until ` | an extra letter |
| S16 | VNI `messsage` | `message ` | an extra letter inside the word (L0 in VNI; in Telex the `ss` is an escape, S74) |
| S17 | `arguement` | `argument ` | an extra letter inside the word |
| S18 | `helpp` | `help ` | a doubled last letter; a four-letter word is allowed as the correction |
| S19 | `committ` | `commit ` | a doubled last letter |
| S20 | `okayy` | `okay ` | a doubled last letter |
| S21 | `servet` | `server ` | neighbouring key `t` for `r`; `sẻvet` was on screen (L5) |
| S22 | `hwllo` | `hello ` | neighbouring key `w` for `e`; `hưllo` was on screen (L5) |
| S23 | `Androdi` | `Android ` | sentence case at the start of the input; the case is kept |
| S24 | `xong. Recieve` | `xong. Receive ` | sentence case after `.`, a sentence start (ENG-R863) |
| S25 | `androdi.` | `android.` | `.` is a closer of prose |
| S26 | `androdi`, Return | `android` and the Return | corrected at Return like at a space (ENG-R1116) |
| S27 | VNI `androdi` | `android ` | plain letters in VNI are candidates too |
| S28 | `(androdi)` | `(android)` | an opening bracket before the word, a closer after it |
| S29 | `- androdi` at a line start | `- android ` | a list marker and a space before the word |
| S30 | `ddi androdi` | `đi android ` | the words around do not matter; the corrected token is `en` for the window |
| S31 | `thier` | `thier ` | three words fit: `their`, `tier`, `thief` |
| S32 | `wierd` | `wierd ` | two words fit: `weird`, `wired` |
| S33 | `pleasee` | `pleasee ` | three words fit: `please`, `pleases`, `pleased` |
| S34 | `grammer` | `grammer ` | no word fits: `e` and `a` are not neighbours |
| S35 | `eah` | `eah ` | three letters (`each` would be the one fit) |
| S36 | `wiht` | `wiht ` | four letters (`with` would be the one fit; restored by L5) |
| S37 | `truong` | `truong ` | the unmarked shape of `trường` (`truing` is one letter away; ENG-R1125 also applies) |
| S38 | `chuop` | `chuop ` | the unmarked shape of a Tier A syllable (`chop` would be the one fit and no Vietnamese keying is one edit away; neighbouring shapes such as `chuot` also bring in ENG-R1125 (2)) |
| S39 | `chinhs` | `chính ` | Vietnamese, kept by L7: not a candidate |
| S40 | `viejt` | `viejt ` | a Vietnamese typo restored by L5; no English word is one edit away |
| S41 | `ability` | `ability ` | an English word shown as typed (L0); `agility` is one neighbouring key away |
| S42 | `server` | `server ` | an English word restored by L5; `sever` is one deletion away |
| S43 | `oauth` | `oauth ` | on the tech-always list (`oath` is one deletion away) |
| S44 | `gradle` | `gradle ` | on the code-only list only (`grade` is one deletion away) |
| S45 | `androdi` with `androdi` on the never-correct list | `androdi ` | the never-correct list |
| S46 | `androdi` with `androdi` on the keep-as-typed list | `androdi ` | the keep-as-typed list (ENG-R1110 (c)); the token is shown as typed, so L0 decides before L2 (re-checked on 19/11/2026) |
| S47 | `ANDRODI` | `ANDRODI ` | capitals |
| S48 | `AndroDi` | `AndroDi ` | mixed case |
| S49 | `ddi Androdi` | `đi Androdi ` | sentence case inside a sentence is a name (`Android` would fit) |
| S50 | `ddi Gramar` | `đi Grẩm ` | the cluster case applies to lowercase words only, so the word keeps its 1.0 behaviour |
| S51 | `Glong` | `Glong ` | shown as typed (L0, before L6), Tier B and an unmarked shape: not a candidate (ENG-R1110 (b), (d)) |
| S52 | `glong` | `glong ` | the same in lowercase: the cluster case needs a display that L6 keeps, and `gong` would be the one fit |
| S53 | `stilll` | `stilll ` | a chat elongation (three `l` at the end; `still` would be the one fit) |
| S54 | `messi` | `messi ` | deleting a last letter that is not doubled is not an edit of the model (`mess`) |
| S55 | `pajama` | `pajama ` | adding a letter after the last one is not (`pajamas`) |
| S56 | `mbank` | `mbank ` | deleting a first letter that is not doubled is not (`bank`) |
| S57 | `leecher` | `leecher ` | `er` -> `ed` is not (`leeched`); the word of REG-37 |
| S58 | `androd1` | `androd1` | the digit commits `androd` and is not a closer (`android` would fit) |
| S59 | `www.exapmle.com` | `www.exapmle.com` | glued to `.`: a link |
| S60 | `kal@exapmle.com` | `kal@exapmle.com` | glued to `@`: an e-mail address |
| S61 | `/opt/locla` | `/opt/locla ` | glued to `/`: a path (`local` would fit) |
| S62 | `#androdi` at the start of the input | `#androdi ` | glued to `#` at a line start: a tag (ENG-R1112) |
| S63 | `well-knwon` | `well-knwon ` | glued to `-`: a compound (`known` would fit) |
| S64 | `weren't` | `weren't` | the apostrophe commits `weren` and is not a closer (`wren` would fit) |
| S65 | `androdi` in the `code` context | `androdi ` | never in `code` |
| S66 | `androdi` with `typoCorrection` off | `androdi ` | the switch (D30 off, D4 off, D8 off, or an app whose rule turns English restore or the restore key off, ENG-R1119) |
| S67 | `androdi` with the macro `androdi` -> `Android Studio` | `Android Studio ` | the macro expands before any decision (ENG-R1103) and is never corrected |
| S68 | `androdi`, space, toggle | `androdi ` | the undo: the typed word is back, the space stays; `neverCorrect(raw: "androdi")` is emitted |
| S69 | `androdi`, space, toggle, toggle | `androdi ` | the second toggle passes through (ENG-R702) |
| S70 | `androdi`, space, Backspace, Backspace | `androi` | the first Backspace re-opens `android`, the second deletes one character of it |
| S71 | `androdi`, space, Backspace, toggle | `androdi` | the toggle right after the re-opening brings the keys back and emits the signal |
| S72 | S68, then `androdi`, space | `androdi androdi ` | the host added `androdi` to the never-correct list after S68 |
| S73 | `androdi`, space, Backspace, space | `android ` | a re-opened corrected token commits unchanged and reports `corrected` again |
| S74 | `messsage` | `message ` | Telex: the `ss` is an escape and L4 (b) keeps `message`, an English word; not a candidate |
| S75 | `ddi pahir` | `đi pahir ` | ENG-R1125: `phair` (`phải`) is one transposition away; `pair` would be the one English fit |
| S76 | `pehis` | `pehis ` | ENG-R1125: `phis` (`phí`) is one deletion away (`penis` would fit) |
| S77 | `hoand` | `hoand ` | ENG-R1125: `hoanf` (`hoàn`) is one neighbouring key away (`hand` would fit) |
| S78 | `chihns` | `chihns ` | ENG-R1125: `chinhs` (`chính`) is one transposition away (`chins` would fit) |
| S79 | `htach` | `htach ` | ENG-R1125 (2): the unmarked shape `thach` is one transposition away (`hatch` would fit) |
| S80 | `androdi…` | `androdi…` | `…` is not a closer (ENG-R1112, the undo needs an ASCII boundary) |
| S81 | `ddi #androdi` | `đi #androdi ` | glued to `#` inside a line |
| S82 | `# androdi` at the start of the input | `# android ` | a heading marker and a space before the word: corrected |
| S83 | `yesss` | `yess ` | Telex: the third `s` escapes the tone and L4 (d) keeps the deliberate form `yess`; not a candidate |
| S84 | `gruop` | `gruop ` | known cost: the transposition of `group` is the unmarked shape of a Tier B syllable (ENG-R1110 (d)) |

---

## 14. Traceability: audit lessons to requirements

| Lesson | Where handled |
|---|---|
| Never crash on any key sequence | ENG-R411, ENG-R640, ENG-T30, REG-01, REG-02 |
| English restore off by default, needed a download | ENG-R106, section 8, REG-03 |
| Quick Telex on by default | ENG-R121, REG-04 |
| VNI restore emitted Telex keys | ENG-R403, ENG-R601, ENG-R705, REG-05 |
| Legacy encodings broken, rarely used | ENG-R120 |
| Backspace across punctuation lost context | section 10.1, REG-07 |
| Backspace changed letters it did not delete | ENG-R710, ENG-R714, ENG-T38, REG-31 |
| Backspace on an escape letter brought the escaped effect back instead of deleting it | ENG-R711, ENG-R714, ENG-T38, REG-24 |
| Backspace tests over real words missed transform orders no word has (`wsaw`, `wzow`, `]ous]`) | ENG-R711, ENG-T38 (every sequence of up to five transform keys) |
| A word re-opened after an automatic restore stayed as typed | ENG-R1005, REG-33 |
| A second tone-removal press could not remove the letter marks | ENG-R411, REG-34 |
| The text a tone-removal key left was restored at commit when it was not a syllable (`dduwowngfzz` gave `dduwowngfzz`) | ENG-R411, L4a, REG-39 |
| A code-context rule turned Vietnamese prose typed in a terminal into shell commands | ENG-R850 (L9 follows the line, not the app), REG-35 |
| A Vietnamese sentence typed in a terminal kept its first word as a shell command | ENG-R850 (sentence condition of L9), ENG-R828 RV5, REG-36 |
| A shell command whose keys are not English became a Vietnamese word in a terminal (`sudo chơn -R`) | ENG-R801, ENG-R850 (L9 right after L5 for a code-only word whose keys are not English), REG-38 |
| English words typed through an escape were committed as the escaped form (`leecher` -> `lecher`, `turn of the light`) | ENG-R804 (rule L4 reads doublings, vowel groups and the context), REG-37 |
| Restore damaged words, names, missing rhymes | sections 3.7 and 3.12, ENG-R843, REG-08 |
| Blocking work per keystroke | ENG-R1210, ENG-R1230 (the engine never blocks; tap threading is in the host spec) |
| Engine not reset after tap re-enable | ENG-R1010, ENG-R1011, REG-22 |
| Keystrokes logged to a file | ENG-R128, ENG-R1220, REG-23 |
| Wrong defaults fixed by "toggle setting X" | ENG-R107, ENG-R450 (few options, right defaults) |
| Per-app special cases never converged | ENG-R851: the engine knows nothing about apps; only `general` / `code` |
| Layout independence (QWERTZ, AZERTY, Dvorak) | section 2, `KeyInput` carries characters, REG-16 |
| Settings export, iCloud sync, per-app memory, smart switch | host and settings specs; the engine has no persistent state |
| Macros (text expansion), restore of the trigger | section 11, ENG-R110, `CommitDecision.macro` |
| Ethnic-minority place names and loanwords restored | Tier B (3.12), ENG-R331, ENG-R843 |
| Escape right after a restore that the words before decided gave nothing back, and the Escape that passed took away the next revision too | ENG-R706, REG-42 |
| Mistyped English words stayed mistyped (`androdi`; `gramar` kept as `grẩm` through a place-name cluster) | section 11A (1.1.0, PRD-R4A): ENG-R1110 to ENG-R1125, ENG-T50 to ENG-T57, S01 to S84 |

---

## 15. Open questions for Pa

Q1 to Q8 were answered on 13/11/2026 and Q9 on 18/11/2026; every answer and the place that implements it is listed in `docs/decisions/0005-pa-decisions-2026-11-13.md` (Q9 also in `docs/decisions/0009-pa-decisions-2026-11-18.md` item 4).

Q10 and Q11 (18/11/2026, the typo correction of section 11A) were answered on 19/11/2026 as recommended (`docs/decisions/0010-pa-decisions-2026-11-19.md` items 1 and 2); the design note `docs/superpowers/specs/2026-11-18-spelling-correction-design.md` gives the reasoning behind each recommendation.

| # | Question (18/11/2026) | Answer |
|---|---|---|
| Q10 | Typo correction of a word in sentence case at the start of a sentence (ENG-R1111): correct it, as `Androdi` -> `Android`, or never correct a capitalised word in 1.1.0? A name that starts a sentence and is one edit from a common word is corrected once (`Biden` would become `Bidden`) until the restore key teaches the never-correct list. The D30 copy (`03-product.md` PRD-R80) follows the answer: "words in all capitals" if they are corrected, "capitalised words" if not. Recommendation: correct it; the first word of a sentence is a word as often as any other, and the guard list of proper names covers most names. | Pa, 19/11/2026: correct it, as recommended. `CorrectionPolicy.sentenceStart` is `.corrected` and the D30 copy reads "words in all capitals". |
| Q11 | Correction at Return and Tab (ENG-R1116): decide at every key that commits, as restore and D29 do, so a chat message leaves with the word corrected and cannot be undone with the restore key; or only at a space or punctuation, so the user sees the word before sending? Recommendation: every key, the rule of P0-3 (13.9.1); Backspace and retyping still work in the next message. | Pa, 19/11/2026: every key, as recommended. `CorrectionPolicy.commitKeys` is `.everyCommitKey`. |

| # | Question | Answer (Pa, 13/11/2026) |
|---|---|---|
| Q1 | Engine licence: MIT or Apache-2.0? | MPL-2.0 (ENG-R109, amended 15/11/2026 before any release); the app is GPL-3.0-or-later (`docs/decisions/0006-app-licence-and-pro-edition.md`). |
| Q2 | Default tone style: traditional (`hòa`, `thủy`) or modern (`hoà`, `thuỷ`, textbook standard since 2018)? | Traditional by default, with the setting to change it (ENG-R510, `03-product.md` D2). |
| Q3 | Review of the ambiguity table: confirm the proposed rows in ENG-R821 and review the top 300 generated candidates. | Lists stay unreviewed for now; unreviewed rows behave as `vi` (ENG-R821). Review later. |
| Q4 | Restore hotkey: unset (first version) or Escape bound by default? | Escape bound by default, with an on/off setting; compatibility rules turn it off in terminals, IDEs and code editors, games and remote desktop clients (7.2, `03-product.md` D8, `02-platform.md` PLT-R353). |
| Q5 | Learn from the user's toggles automatically (after two identical signals) or only on explicit confirmation? | Automatic, but learned entries are stored per app; entries typed in settings stay global (ENG-R862). |
| Q6 | Macro triggers are matched on raw keys (ENG-R1102); is the trigger character set (printable ASCII, no Vietnamese letters) acceptable? | Yes, keep the current set. |
| Q7 | Attested-syllable source: Vietnamese legal texts plus Pa's additions, or hand curation only? | Keep the current attested sources (legal texts plus reviewed additions). |
| Q8 | Keep teencode `z` onset and `k` coda in v1, and add the `dz` onset (P0-2)? `f`, `j`, `w` stay out. | Keep, plus `dz` (resolved earlier the same day). |
| Q9 | (15/11/2026) After a tone-removal key removed the marks (ENG-R411), the commit decides by 8.1 like any token, so an unmarked spelling that is not a syllable is restored: `dduwowngfzz` shows `duong` and Space gives `dduwowngfzz` (L5), as `vieejtz` already did. Should a removal make the commit keep the unmarked text like an escape (L4: keep it unless the raw keys are English)? | Decided 18/11/2026 by the product owner: keep (`docs/decisions/0009-pa-decisions-2026-11-18.md` item 4). Rule L4a (8.1, ENG-R411, REG-39) applies when the removal key is the last key of the token: `dduwowngfzz` + space gives `duong`, `vieejtz` gives `viêt`, `daauszz` gives `dau`. |
