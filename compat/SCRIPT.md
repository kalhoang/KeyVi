# Compatibility script (12 steps, under 3 minutes per app)

Specification: QA-R17 to QA-R21 ([spec/04-quality-release.md](../spec/04-quality-release.md) section 2.6), PRD-R35, PRD-R39, PLT section 13.3. The behaviour rules live in `compat/rules.json`; the verification status lives in `compat/matrix.json`. This script produces the evidence for the second file.

Use it to verify one app on one macOS version, or to file a community "Compatibility report" issue (QA-R20). A maintainer confirms a community result before the status becomes `Hoạt động tốt`.

## 0. Before you start (30 seconds)

1. Install the build you are testing and grant its permission. The menu-bar icon shows `V` (Vietnamese) when it is ready.
2. Quit any other Vietnamese input method. Two at once cause doubled letters and spoil the result.
3. Open the app and create a **new, empty** document, note, message box or text field. Use a throwaway place: never a real conversation, and never a password field. Do not type private text. Use only the test text below.
4. Note the facts you will record (section 3). Quick ways to get them:

   ```sh
   mdls -name kMDItemCFBundleIdentifier -name kMDItemVersion "/Applications/<App>.app"
   sw_vers
   ```

5. Set the method in the menu to **Telex** for steps 1, 3 to 12. Step 2 switches to **VNI**; switch back to Telex afterwards.
6. If the menu shows a lock badge (Secure Input) or a slashed icon, stop: record the result as `n/a` with the note "secure input" or "no permission", and see [docs/support/replies.md](../docs/support/replies.md).

New lines: in chat apps Return sends the message, so use Shift+Return (or Option+Return) for a new line, or simply type the lines one after another with a space between them. Never press Return where it would send or submit something.

How to read "type": type exactly the characters shown in the code block, including spaces and punctuation, at a normal pace unless the step says otherwise. The expected result is below each block.

## 1. The 12 steps

### Step 1: Telex paragraph with all six tones

Type (Telex), one line at a time (new line as described in section 0):

```text
Tieengs Vieetj cos saus thanh ddieeuj: ngang, sawcs, huyeenf, hoir, ngax, nawngj.
Hoom nay trowfi ddepj, chungs tooi dduwowcj ddi chowi owr Ddaf Lajt.
Nguwowfi Vieetj yeeu quys ddaats nuwowcs, thuwowng nhau nhuw nguwowfi thaan.
Thuyr hoaf khoer, quyeenf
```

Expected:

```text
Tiếng Việt có sáu thanh điệu: ngang, sắc, huyền, hỏi, ngã, nặng.
Hôm nay trời đẹp, chúng tôi được đi chơi ở Đà Lạt.
Người Việt yêu quý đất nước, thương nhau như người thân.
Thủy hòa khỏe, quyền
```

Pass: the text is identical, with no lost, doubled or reordered letters, and each word appears once. The last line shows the default traditional tone placement (`hòa`, `thủy`, `khỏe`); if the tester switched to modern placement, `hoà`, `thuỷ`, `khoẻ` are also correct. Record `fail` for any difference and write the first wrong word in the note (a word is enough; do not paste private text).

### Step 2: VNI paragraph with all six tones

Switch the method to **VNI** in the menu, then type:

```text
Tie61ng Vie65t co1 sa1u thanh d9ie6u5: ngang, sa81c, huye6n2, hoi3, nga4, na8ng5.
Ho6m nay tro7i2 d9e5p, chu1ng to6i d9u7o7c5 d9i cho7i o73 D9a2 La5t.
Ngu7o7i2 Vie65t yeu6 quy1 d9a61t nu7o7c1, thu7o7ng nhau nhu7 ngu7o7i2 tha6n.
Thuy3 hoa2 khoe3, quye6n2
```

Expected: exactly the same four lines as in step 1. Pass criteria as step 1. Switch back to **Telex** afterwards.

### Step 3: English words stay unchanged (Telex)

Type, with a space after each word and a final space:

```text
text user wifi USB 
```

Expected: `text user wifi USB ` unchanged (no `tẽt`, `úer`, `wifi` with marks, or `ƯSB`). Pass: identical. Also try one boundary key other than Space: type `text,` and `user.` and confirm they stay `text,` and `user.` (automatic restore works on every boundary key, P0-3).

### Step 4: Edit a word after `, `

Type:

```text
chao, 
```

(the letters `chao`, a comma, a space). Press Backspace **twice** (removing the space and the comma, which re-opens the word `chao`), then type `f`.

Expected: the word becomes `chào` (the app shows `chào`, and no extra letter `f`). Pass: `chào`. In VNI repeat with the key `2` instead of `f`. This tests re-entry across `, ` (REG-07).

### Step 5: Delete and retype the first character of a line

On a new line (or after clearing the field) type `Tieengs` (shows `Tiếng`). Press Backspace until the line is empty (five presses). Type `Tieengs` again.

Expected: the second result is `Tiếng`, once, with the capital `T` present and nothing left over from the first attempt. Pass: `Tiếng`.

### Step 6: First character of an empty field

Click into a completely empty field (a new note, an empty search box, an empty cell) and type:

```text
ddi 
```

Expected: `đi ` (the first letter is not swallowed, not doubled, and the field shows `đi`). In VNI the keys are `d9i `. Pass: `đi`. This catches the "first letter lost" class of bug.

### Step 7: Type at 15 keys per second

Type this line (40 keys including spaces) in about 3 seconds (at least 13 keys per second; use a stopwatch, a short burst is enough):

```text
Nguwowfi Vieetj yeeu quys ddaats nuwowcs 
```

Expected: `Người Việt yêu quý đất nước ` with no lost, doubled or misplaced letters. Repeat once. Pass: both runs correct. A single wrong run is a `fail` (burst typing).

### Step 8: Toggle hotkey

1. Tap Control and Shift together and release (the default VI/EN toggle). The menu-bar icon changes to `E`.
2. Type `tieengs ` and expect `tieengs ` (plain English).
3. Tap Control+Shift again (icon `V`), type `tieengs ` and expect `tiếng `.

Pass: both results as expected, and the app does not react to the Control+Shift tap in any other way (no menu opening, no stray characters). If the app uses Control+Shift for something else, record that in the note.

### Step 9: Expand a macro

Prepare once in Settings, Macros: add `vn` for `Việt Nam`. Then type:

```text
vn 
vn.
```

Expected: `Việt Nam ` and `Việt Nam.` (the space and the full stop are kept). Pass: both correct and nothing doubled. For apps that treat Return specially, use a space or punctuation as the terminator, never Return.

### Step 10: Autocomplete is not duplicated

If the app has autocomplete or inline completion (a browser address bar, a spreadsheet cell, a search or suggestion field), type a word whose start the app can complete, using a Vietnamese word that exists in the same column, history or page. Example: after typing `Việt Nam` in one spreadsheet row, type `Vieetj` in the next row. For an address bar, use the start of a site you have visited.

Expected: the completion suggestion may appear, but the field does not contain duplicated or leftover letters such as `Việtt`, `Việt Việt` or a missing first letter, once you finish the word and press Space or Tab as the app requires. Pass: no duplication. If the app has no autocomplete, record `n/a`.

### Step 11: Undo (Command+Z)

Clear the field. Type `Tieengs Vieetj ` and press Command+Z once.

Expected: the app's own undo removes sensible text, for example the last word or the whole typed run, and leaves no half-composed text such as `Tieeng`, a stray `s`, or a lone accent. Pass: what remains is sensible (nothing, `Tiếng`, or the previous full word). Record exactly what remained in the note. If the app has no undo, record `n/a`.

### Step 12: No stray invisible characters

Select all in the field, copy, and inspect the bytes in Terminal:

```sh
pbpaste | xxd
```

Expected: only the bytes of the visible text, in precomposed (NFC) form. Check that none of these appear:

| Bytes | Character |
|---|---|
| `e2 80 8b` | zero width space (U+200B) |
| `e2 80 8c`, `e2 80 8d` | zero width non-joiner or joiner (U+200C, U+200D) |
| `e2 81 a0` | word joiner (U+2060) |
| `ef bb bf` | byte order mark or zero width no-break space (U+FEFF) |
| `cc 80` to `cc a3` (combining marks) | decomposed (NFD) text instead of NFC |

For example `ế` must be `e1 ba bf`. Pass: none of the unwanted bytes. A trailing newline (`0a`) from `pbpaste` is normal.

## 2. What to record

For each run record the following. This is the evidence that goes into `compat/matrix.json` and into the issue form.

| Item | Where to find it |
|---|---|
| Date of the run (UTC or local, say which) | Your clock |
| App display name and bundle ID | `mdls` command above |
| App version | `mdls` command above |
| App category (browser, office, chat, notes, developer, terminal, design, launcher, remote, game, system, other) | Your judgement |
| macOS version and build | `sw_vers` |
| {{AppName}} version and build, channel | Menu, About & Support |
| Architecture (Apple silicon or Intel) | Apple menu, About This Mac |
| Result of each of the 12 steps: `pass`, `fail`, `n/a` | This script |
| For each `fail`: the first wrong word or the observed symptom (lost, doubled, wrong tone, out of order, lag) | Your eyes |
| Matched rule ID and the injection strategy shown | Menu, Diagnostics window (the matched rule is shown there) |
| Diagnostics block (the in-app report; it contains no typed text) | Menu, Report a problem |
| Does the same failure happen in the {{AppName}} practice field? | Report window, practice field button |
| Verifier name or GitHub handle | You |

If the result is `fail`, also save the diagnostics block for the issue. Never paste private text.

## 3. Mapping to the matrix columns

The matrix columns (PLT section 13.3) come from the steps:

| Matrix column | Steps |
|---|---|
| Telex basic | 1, 3, 11, 12 |
| VNI basic | 2 |
| Inline completion | 10 |
| Burst typing | 7 |
| Backspace re-entry across `, ` | 4 (and 5) |
| Macro expansion | 9 |
| Toggle hotkey | 8 (no cell of its own in the schema: a failure lowers the status and is explained in the note) |
| Restore hotkey | Optional check A below; otherwise `n/a` |
| Per-app memory | Optional check B below; otherwise `n/a` |

Optional check A (only if a restore-last-word hotkey is set): type `Tieengs`, press the hotkey once and expect `Tieengs`; press it a second time and expect the key to reach the app with its normal meaning (ENG-R701, ENG-R702).

Optional check B: set this app to Vietnamese, switch to another app and set that one to English, then return. The first key typed in the first app must already be in Vietnamese (PRD-R19).

A failure on a Tier 1 app blocks a stable release (spec/04-quality-release.md section 1, quality goals).

## 4. Choosing the status

| Result | `status` in `compat/matrix.json` | Shown to users (vi) | Note |
|---|---|---|---|
| All applicable steps pass | `works` | `Hoạt động tốt` | Verified on a recent version |
| All pass but one needs a caveat | `worksWithNotes` | `Hoạt động, có lưu ý` | One user-facing line, for example "Trong ô địa chỉ, gợi ý tự động có thể bị tắt khi đang gõ dấu." |
| Cannot be run, or older than 120 days | `notVerified` | `Chưa kiểm tra` | After 120 days without verification an entry displays as this automatically (QA-R19) |
| A step fails and no rule can fix it | `knownLimitation` | `Hạn chế đã biết` | Plain explanation and workaround; VERIFY each limitation before publishing |

## 5. Add or update a row in `compat/matrix.json`

The file is the single source for the in-app Apps page and the website matrix (QA-R17, PRD-R35, PRD-R38). Its JSON Schema is in `compat/schema/`; if this section and the schema ever differ, the schema wins and this section must be fixed.

1. Run the 12 steps (sections 1 and 2).
2. Open `compat/matrix.json`. Find the entry by bundle ID. If it exists, update it; if not, add a new entry.
3. Fill the fields of QA-R17. The names are those of `compat/schema/matrix.schema.json`:

   | Field | Meaning | Required |
   |---|---|---|
   | `bundleId` | `CFBundleIdentifier` of the app | always |
   | `displayName` | Name users know | always |
   | `category` | `browser`, `office`, `chat`, `notes`, `developer`, `terminal`, `design`, `launcher`, `remote`, `game`, `system` or `other` (section 2) | always |
   | `tier` | `1` or `2` per PRD-R39; leave it out for untiered apps | no |
   | `ruleId` | The rule ID shown in Diagnostics; leave it out when the default applies | no |
   | `status` | `works`, `worksWithNotes`, `notVerified` or `knownLimitation` (section 4) | always |
   | `note` | `{ "vi": "...", "en": "..." }`: one plain sentence in each language | with `worksWithNotes` and `knownLimitation` |
   | `lastVerified` | Date of the run, `YYYY-MM-DD` | with `works` and `worksWithNotes` |
   | `appVersion` | Version of the tested app | with `works` and `worksWithNotes` |
   | `macOS` | macOS version of the test Mac, for example `27.1` | with `works` and `worksWithNotes` |
   | `verifier` | Handle or name | with `works` and `worksWithNotes` |
   | `issues` | Issue numbers (integers) for failures or limitations; `[]` when there are none | always |
   | `checks` | Per-step cells, below | no |

   Fill `checks` with one cell per matrix column of section 3: `telexBasic`, `vniBasic`, `inlineCompletion`, `burstTyping`, `backspaceReentry`, `restoreHotkey`, `perAppMemory`, `macroExpansion`. Each cell is `{ "result": "pass" | "fail" | "n/a", "date": "YYYY-MM-DD", "tester": "..." }`. Toggle hotkey has no cell; record a failure of it in the status and the note.
4. Validate the file against the schema: `scripts/lint.sh` runs `python3 -I scripts/check-matrix.py`, which you can also run alone. Then run `node site/build.mjs` to see the matrix page.
5. A new per-app rule needs more than a data entry: add an integration test that reproduces the app's behaviour in `TestHost/` (QA-R21).
6. Open a pull request. A community-provided row is marked unconfirmed until a maintainer confirms it (QA-R20).

Illustrative file with one entry (values are examples, not real results; the field names are exactly those of the schema, and `scripts/tests/test_scripts.py` validates this example against it):

```json
{
  "schemaVersion": 1,
  "entries": [
    {
      "bundleId": "com.example.Editor",
      "displayName": "Example Editor",
      "category": "developer",
      "tier": 2,
      "ruleId": "editor.example.default",
      "status": "worksWithNotes",
      "note": {
        "vi": "Gợi ý tự động có thể tắt trong lúc gõ dấu.",
        "en": "Autocomplete may pause while a tone mark is typed."
      },
      "lastVerified": "2026-11-13",
      "appVersion": "1.0",
      "macOS": "27.1",
      "verifier": "github-handle",
      "issues": [],
      "checks": {
        "telexBasic": { "result": "pass", "date": "2026-11-13", "tester": "github-handle" },
        "vniBasic": { "result": "pass", "date": "2026-11-13", "tester": "github-handle" },
        "inlineCompletion": { "result": "n/a", "date": "2026-11-13", "tester": "github-handle" },
        "burstTyping": { "result": "pass", "date": "2026-11-13", "tester": "github-handle" },
        "backspaceReentry": { "result": "pass", "date": "2026-11-13", "tester": "github-handle" },
        "restoreHotkey": { "result": "n/a", "date": "2026-11-13", "tester": "github-handle" },
        "perAppMemory": { "result": "n/a", "date": "2026-11-13", "tester": "github-handle" },
        "macroExpansion": { "result": "pass", "date": "2026-11-13", "tester": "github-handle" }
      }
    }
  ]
}
```

## 6. Cadence (QA-R19)

| Group | When |
|---|---|
| Tier 1 | Every stable release candidate |
| Tier 2 | Every minor release |
| All entries | After each macOS major release and after point releases that touch input (first beta and GM) |
| Any entry older than 120 days | Shown as `Chưa kiểm tra` on the website and in the next app build |
| Tier 1 rows at release time | At most 90 days old, on the latest macOS 26 and 27 (PLT section 13.3) |

The Tier 1 and Tier 2 app lists are owned by PRD-R39 ([spec/03-product.md](../spec/03-product.md) section 9) and are not repeated here.
