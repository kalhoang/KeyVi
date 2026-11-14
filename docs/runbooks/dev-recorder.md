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
   to compare what the app shows with what {{AppName}} believes it typed.
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
| `readbackMismatch` | the field text before the caret does not end with what {{AppName}} typed since the last boundary |
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
path; an `injectionProblem` with `axTimedOut` in a given rule points at that app's compat rule.

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
| `file` | `v` format version (1), `launch` ID, `app` version, `build` marker |
| `start`, `stop` | `launch`, `app` (start); the recorder started or the app quit |
| `pause`, `resume` | `until` (pause end, microseconds) |
| `settings` | `s`: name to value (typing method, tone placement, English restore, Telex options, macros on and counts, hotkeys, word-list counts, global mode, safe mode) |
| `focus` | `gen`, `bundle`, `role`, `subrole`, `rule`, `strat`, `rtf` (requireTextFocus), `ax`, `secure`, `mode`, `modeSrc`, `ctx` (engine context), `er` (English restore), `mac` (macros), `pause` |
| `key` | `ev` (keyDown, keyUp, flagsChanged, mouseDown), `kc` key code, `fl` CGEventFlags, `ch` layout character, `out` (passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp) |
| `engine` | `act` (passThrough, edit, editThenPassThrough), `del`, `ins`, `comp` token after the key, `dec` commit decision |
| `boundary` | `reason` (the engine's reset reason), `job` (the boundary job reason) |
| `job` | `seq`, `gen`, `kind` (compose, backspaceRecompose, restore, macro, reentry), `strat`, `out`, `delN`, `insN`, `posted`, `totalUs` (from the key), `runUs` (execution) |
| `fallback` | `seq`, `from`, `to`, `reason` |
| `readback` | `reason` (backspaceEdit, commit, marker), `status` (ok, skippedRule, skippedSecure, skippedNoField, skippedBusy, unavailable, timedOut, failed), `text`, `selLoc`, `selLen`, `bundle`, `rule` |
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
- Readback findings skip fields with a selection and readbacks taken within 100 ms of a key.
- The readback never runs beside an edit job: it waits while a job is queued or in flight (20 ms at a time, at most
  1 s after its trigger, then `skippedBusy`) and stops between its reads if a job starts. It reads through its own
  AX reference to the app's focused element (`skippedNoField` when that is no longer the field of the focus
  snapshot), so the worker's AX element and its messaging timeout stay untouched.
- A trace can hold only what the tap and the ax thread saw; text changed by the app itself (autocorrect, completion)
  shows up as a `readbackMismatch`, not as its own line.
