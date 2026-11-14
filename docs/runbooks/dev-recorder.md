# Runbook: the dev recorder (typing log of development builds)

Owner: the maintainer. Specification: PLT-R904A (`spec/02-platform.md` section 9). Decision:
[ADR 0007](../decisions/0007-dev-recorder.md). Code: `Packages/AppCore/Sources/Diagnostics/DevRecorder*.swift`,
`Packages/AppCore/Sources/InputHost/DevRecorder/`, `App/Sources/Diagnostics/DevRecorder*.swift`, the scanner in
`Packages/AppCore/Sources/TraceScanCore/` and `scripts/dev/trace-scan.sh`.

Development builds (the Debug configuration) record typing all the time, so a bug met while working can be read
afterwards. Release builds do not contain the recorder at all; `scripts/verify-release.sh` checks that.

## 1. For Pa: using the dev build

1. **Get the dev build.** The integrator builds it from the checkout:
   `xcodegen generate && xcodebuild -project App.xcodeproj -scheme App -configuration Debug build`. Debug builds are
   signed with the Apple Development identity and use the development bundle ID, so their permissions are separate
   from the release app's. Quit the release app (and any other input method's typing app) before using the dev build.
2. **It records from launch.** Nothing to switch on and no confirmation. A small dot on the top left of the menu bar
   icon shows that it records; VoiceOver reads "Đang ghi nhật ký gõ" with the icon's label. The top of the menu
   says "Đang ghi nhật ký gõ (bản dev)".
3. **What it records:** every key with the character of your keyboard layout, what the typing engine did with it,
   how {{AppName}} changed the text in the app (and whether that worked, how long it took), focus changes (app ID and
   field type only, never window titles or web addresses), resets with their reason, VI/EN switches, the settings
   that change typing, and from time to time the text just before the cursor in the field (at most 64 characters),
   to compare what the app shows with what {{AppName}} believes it typed. That text is read only when you have
   stopped typing for a second, never while you type.
4. **What it never records:** anything while a password field has focus or Secure Keyboard Entry is on, anything
   while paused, and the text of apps whose compatibility rule keeps {{AppName}} away from accessibility (Electron
   apps such as Slack or VS Code: there only keys and edits are recorded, never the field text).
5. **Where and how long:** `~/Library/Logs/{{AppName}}/dev-traces/`, one file per hour (`YYYYMMDD-HH.jsonl`), only
   your user can read them, Time Machine skips them. Files older than 7 days are deleted, and the folder never grows
   past 200 MB. "Mở thư mục nhật ký" in the menu opens the folder.
6. **When something goes wrong while typing:** press **Control+Option+Command+;** (semicolon) right away, in the app
   you are typing in, and keep working. The icon flashes for a second; nothing else happens and the app does not
   receive the keys. "Đánh dấu lỗi vừa gặp" in the menu does the same. Later, tell the integrator roughly when it
   happened; the marker makes it easy to find. Fixing a word with several Backspaces is noticed too, even without a
   marker.
7. **Pause:** "Tạm dừng ghi 30 phút" stops recording for 30 minutes (the dot disappears, the menu says until when);
   "Tiếp tục ghi" resumes at once. Quitting and starting the app again also resumes.

## 2. For the integrator: reading the log

The scanner reads a folder of trace files and prints to standard output only. It never writes, moves, deletes or
sends anything. From the checkout root (the first run builds it in release mode, about a minute):

```sh
scripts/dev/trace-scan.sh summary                    # everything in the dev build's folder
scripts/dev/trace-scan.sh summary --since 2h         # the last two hours
scripts/dev/trace-scan.sh summary --date 2026-11-14  # one local day
scripts/dev/trace-scan.sh show 3 --since 2h          # finding 3 of that summary, 30 s before and 10 s after
scripts/dev/trace-scan.sh show 3 --since 2h --before 60s --after 20s
scripts/dev/trace-scan.sh summary --dir /path/to/copied/dev-traces
scripts/dev/trace-scan.sh --print-dir                # where the dev build writes
```

Without the wrapper: `swift run --package-path Packages/AppCore -c release trace-scan summary --dir <folder>`. `show N`
numbers findings exactly like the summary with the same selection, so repeat the `--since` or `--date` (with
`--since`, run both commands close together, or pin the clock with `--now 2026-11-14T10:00:00Z`). `--no-replay` skips
finding (h) for a faster scan.

### 2.1 What a summary shows

Metadata only: files and hours, launches, key downs per app, counts of engine steps, jobs, readbacks and markers,
gaps (secure input, secure field, overflow) and pauses, unreadable lines, then one numbered line per finding:
local time, app bundle ID, compat rule, finding kind and a detail made of names and numbers.

| Kind | Meaning |
|---|---|
| `marker` | Pa pressed the chord or used the menu item |
| `backspaceEdit` | a Backspace made the engine delete more than one character or insert something |
| `correctionBurst` | three or more Backspaces within 1.5 s, within 2 s after the engine transformed a word, then retyping: Pa fixing a wrong word without a marker |
| `readbackMismatch` | the field text before the caret does not end with what {{AppName}} typed since the last boundary, and the difference is not one of the two kinds below; the scanner then takes the field's text as the new baseline, so one divergence gives one finding |
| `keyDropped` | the same, explained: exactly one character of a key the tap passed is missing from the field. The detail says how long before the readback the key went down and whether a readback was in flight when it went down, started within 200 ms after it, or was nowhere near; `show` names the character |
| `extraCharacter` | the same, explained: the field holds exactly one character {{AppName}} did not type (autocorrect, a Backspace the app ignored); `show` names it |
| `slowReadback` | a readback timed out, or its AX calls took more than 30 ms (longer than one AX call of the inject worker may take, so {{AppName}}'s own reads would time out in that field) |
| `resetWithOpenToken` | a boundary the user did not cause (focus change, late focus, revalidation, configuration, an unknown reason) while a word was being composed |
| `injectionProblem` | an edit job that failed, fell back to another strategy (with the reason, AX timeouts included) or took more than 50 ms |
| `restoreOrReopen` | an Escape restore or a Backspace that re-opened a committed word |
| `replayDivergence` | replaying the keys since the last reset through the engine with the recorded settings gives another result than recorded: the host fed the engine something else, or kept state it should have dropped |
| `undoAfterEdit` | Command+Z within 2 s after an engine edit |

### 2.2 Reading an excerpt

`show N` prints the finding's header, then every line of the window in time order with the time relative to the
finding; `>` marks the finding's own line. Keys print as in the PLT-R905 review window (`key keyDown 0x33 - -
passed`), engine steps with the edit and the token after it, then jobs (`job 12 compose backspaceReplace executed
... 4 events 3.1 ms total`), fallbacks, boundaries (`boundary focusChanged / focusChanged`), focus snapshots (bundle,
role, rule, strategy, requireTextFocus, mode), readbacks with the field text, markers, settings and gaps.

Typical readings: a `resetWithOpenToken` just before the letters of a word went missing points at a focus or
revalidation boundary (W8-A territory); a `backspaceEdit` followed by a `readbackMismatch` points at the Backspace
path; an `injectionProblem` with `axTimedOut` in a given rule points at that app's compat rule. A `keyDropped` whose
detail says a readback was in flight when the key went down, or started a few tens of milliseconds after it, points
at the recorder itself (section 5); one with no readback near it happened without the observer, in the app or the
system. A `slowReadback` in an app tells how slowly it answers accessibility requests; repeated ones next to
`injectionProblem` lines with `axTimedOut` say the app is busy, not the strategy wrong.

`show` prints a finding's note under its detail: for `keyDropped`, `extraCharacter` and an explained
`readbackMismatch` it names the character (`keyDropped: "c" passed at -1020 ms, absent from the field`). The note
is typed content: it appears in `show` only, never in the summary.

### 2.3 Privacy while reading

- Read the summary first; it has no typed content.
- Open excerpts only around findings, and quote only what a bug report needs.
- The files stay on Pa's Mac. Copy a folder elsewhere only with Pa's agreement, and delete the copy afterwards.
- Never attach a trace file or an excerpt to a public issue.

## 3. File format

One JSON object per line. Every line has `type` and `t` (microseconds since 1970, wall clock). Each file the app
opens starts with a `file` line, the settings and the focus in effect, so every file can be read on its own.

| `type` | Fields |
|---|---|
| `file` | `v` format version (2 since the readback timing fields; files of the first day are 1), `launch` ID, `app` version, `build` marker |
| `start`, `stop` | `launch`, `app` (start); the recorder started or the app quit |
| `pause`, `resume` | `until` (pause end, microseconds) |
| `settings` | `s`: name to value (typing method, tone placement, English restore, Telex options, macros on and counts, hotkeys, word-list counts, global mode, safe mode) |
| `focus` | `gen`, `bundle`, `role`, `subrole`, `rule`, `strat`, `rtf` (requireTextFocus), `ax`, `secure`, `mode`, `modeSrc`, `ctx` (engine context), `er` (English restore), `mac` (macros), `pause` |
| `key` | `ev` (keyDown, keyUp, flagsChanged, mouseDown), `kc` key code, `fl` CGEventFlags, `ch` layout character, `out` (passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp) |
| `engine` | `act` (passThrough, edit, editThenPassThrough), `del`, `ins`, `comp` token after the key, `dec` commit decision |
| `boundary` | `reason` (the engine's reset reason), `job` (the boundary job reason) |
| `job` | `seq`, `gen`, `kind` (compose, backspaceRecompose, restore, macro, reentry), `strat`, `out`, `delN`, `insN`, `posted`, `totalUs` (from the key), `runUs` (execution) |
| `fallback` | `seq`, `from`, `to`, `reason` |
| `readback` | `reason` (backspaceEdit, commit, marker), `status` (ok, skippedRule, skippedSecure, skippedNoField, skippedBusy, unavailable, timedOut, failed), `text`, `selLoc`, `selLen`, `bundle`, `rule`; from version 2: `durUs` (the AX calls, timeouts included; absent when none was made), `waitUs` (from the first trigger to the read), `idleUs` (time since the last key, click or job when the read started), `overlap` (present and true when a key or click went down while the read was in flight). `t` is when the read started |
| `marker` | `src` (chord, menu) |
| `mode` | `mode`, `manual`, `bundle` |
| `gap` | `reason` (secureInput, secureField, overflow), `end` (microseconds) or `dropped` (records lost) |

A key line comes first; the engine step and any boundary of the same key carry the same `t`. A boundary found while
reconciling (a focus change seen by the next key) is stamped with that key's time and comes before its engine step.
The order holds across drains too: a drain pops the recorder's own rings before the shared key ring, so a key typed
during a drain is never written after its engine step. Focus changes inside a gap or a pause are not recorded; when
the gap ends or recording resumes, a `focus` line with the focus in effect follows, so the lines after it are
attributed to the right field.

## 4. Limits

- Resets the pipeline makes outside a hard boundary (entering fail-open, a full job queue) have no boundary line;
  a `replayDivergence` right after a posting failure may come from that.
- Replay uses the bundled word lists only. Commits decided by the user's own lists or by a macro stop the replay of
  that segment without a finding.
- Readback findings skip fields with a selection, readbacks taken within 100 ms of a key, and readbacks with
  `overlap` (a key went down while they were in flight, so the text may show the field half way through it).
- The readback reads only in a typing pause: 1 s without a key or click going down and without an edit job (a
  queued or in-flight job postpones it like a key). Every trigger since the last read (commits, Backspace edits,
  markers) waits for the same pause and gives one read, recorded with the most specific reason; while Pa types
  without a 1 s pause there is no read at all. At most one read per 300 ms. It stops between its AX calls if a job
  starts (`skippedBusy`). It reads through its own AX reference to the app's focused element (`skippedNoField` when
  that is no longer the field of the focus snapshot), so the worker's AX element and its messaging timeout stay
  untouched.
- The explanation of a mismatch names the one character whose absence (or presence) makes the texts agree. When
  later edits deleted across the missing character, the texts may agree only without a neighbour, or not at all;
  read the excerpt before trusting the name. Among equal neighbours (`cc`) the scanner names the key a readback was
  near, else the last one.
- When a Backspace reached past what the scanner saw typed, its view is unknown; the next readback it may compare
  gives the baseline back, so later divergences are still found.
- Files of the first day (format version 1) have no readback durations: a readback started before a key counts as
  possibly in flight for up to 150 ms (three AX calls of at most 50 ms), and only `timedOut` readbacks are slow.

## 5. The readback and WebKit editors

On 2026-11-14, the first day on Pa's Mac, the scanner found two incidents in a native app whose editor is a
WKWebView (no compat rule matched it, so the readback ran): a key the tap passed through never reached the field,
and in both the key went down 27 ms and 71 ms before a commit readback of the first recorder started (it read
300 ms after a commit, that is while Pa typed the next word). The likely cause is the read racing WebKit's handling
of that key, on a Mac under heavy memory pressure. {{AppName}} itself holds keys while a job reads accessibility, so
it never races this way; the recorder cannot hold keys (observer rule), so since then it reads only in a pause.

WebKit editors keep their readback (ADR 0007 decision 11): with the pause rule, a read no longer meets a key on its
way to the app unless one goes down during the read itself, which the line flags. Revisit when a version 2 trace
shows a `keyDropped` whose detail names a readback in flight or started right after the key: then skip the readback
in fields inside a web area, and record the decision in ADR 0007.
- A trace can hold only what the tap and the ax thread saw; text changed by the app itself (autocorrect, completion)
  shows up as a `readbackMismatch`, not as its own line.
