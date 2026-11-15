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
