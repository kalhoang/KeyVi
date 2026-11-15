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
finding (h) for a faster scan. The replay runs only on segments written by the scanner's own engine build (the
`eng` identity of format version 3, ADR 0007 decision 13); the summary ends with one `Replay:` line counting the
segments it skipped, and `--replay-anyway` replays them too (expect divergences that are only rule changes). A
`--since` window that starts inside a file keeps that file's last `file`, `settings` and `focus` lines from before
the window as context (they make no findings), so findings name the app and the replay knows the settings and the
engine build.

### 2.1 What a summary shows

Metadata only: files and hours, launches, key downs per app, counts of engine steps, jobs, readbacks and markers,
gaps (secure input, secure field, overflow) and pauses, unreadable lines, then one numbered line per finding:
local time, app bundle ID, compat rule, finding kind and a detail made of names and numbers. An app the focus reader
could not name appears as the frontmost application in parentheses (`(com.example.app)`, format version 3) or `-`.
Since the frontmost-app fallback of PLT-R381 (2026-11-15) such an app also gets its bundle-level compat rule and its
per-app mode, so the finding names that rule; the parentheses still say that Accessibility did not name the app.
When Accessibility starts or stops naming that same app (still without a focused field), a new focus line with the
same `gen` switches between `bundle` and `front`.

| Kind | Meaning |
|---|---|
| `marker` | Pa pressed the chord or used the menu item |
| `backspaceEdit` | a Backspace made the engine delete more than one character or insert something |
| `correctionBurst` | three or more plain Backspaces within 1.5 s, within 2 s after an engine edit that changed letters of a word, then retyping: Pa fixing a wrong word without a marker. Option+Backspace and Command+Backspace end a burst |
| `readbackMismatch` | the field text before the caret does not end with what {{AppName}} typed since the last boundary, and the difference is not one of the two kinds below; the scanner then takes the field's text as the new baseline, so one divergence gives one finding |
| `keyDropped` | the same, explained: exactly one character of a key the tap passed is missing from the field, possibly before a later edit that deleted by count around it ("mục" read back as "ục"). The detail says how many passed keys fit, names the first press of a key after its keyUp was held and replayed when one fits (ADR 0322), and whether a readback was in flight when the key went down, started within 200 ms after it, or was nowhere near; `show` names the character |
| `unseenKey` | a keyUp whose keyDown the tap never saw: the app received a key {{AppName}} did not (secure input hid it, PLT-R397A). Not reported within 1 s after a gap, a pause or the start of the selection; a readback finding after it says so; `show` gives the key code |
| `extraCharacter` | the same, explained: the field holds exactly one character {{AppName}} did not type (autocorrect, a Backspace the app ignored); `show` names it |
| `slowReadback` | a readback timed out, or one of its AX calls took more than 30 ms (longer than one AX call of the inject worker may take, so {{AppName}}'s own reads would time out in that field; the scanner compares the longest single call, not the sum of the read's calls) |
| `resetWithOpenToken` | a boundary the user did not cause (focus change, late focus, revalidation, configuration, an unknown reason) while a word was being composed |
| `injectionProblem` | an edit job that failed, fell back to another strategy (with the reason, AX timeouts included) or took more than 50 ms |
| `restoreOrReopen` | an Escape restore, a Backspace that re-opened a committed word, or a Backspace that re-opened a token a rule restored at its commit |
| `reopenedLiteral` | the ENG-R1005 regression guard: a Backspace re-opened a token a rule restored at its commit (not one the user restored with the toggle), at least one more Backspace went into it, and then keys passed through as typed although the token shown before them no longer had a key that transforms anything and a fresh token with those keys would have composed them (`tiesng`, space, five Backspaces, `eesn` showing `tieesn`). The scanner replays the shown token through its own engine with the recorded settings, so this needs replay (not with `--no-replay`) and judges traces of any engine build; a token still open at the end of the selection or cut by a gap or a pause is not judged; at most one per token. The detail gives the commit decision and the counts only; `show` shows the excerpt, where the engine lines already carry the token as the recorder wrote it. It should never fire on a build with ENG-R1005 |
| `replayDivergence` | replaying the keys since the last reset through the engine with the recorded settings gives another result than recorded: the host fed the engine something else, or kept state it should have dropped. Only for segments written by the scanner's engine build; a segment stops at a gap or a pause. Return and Tab are fed to the engine before their boundary, which the recorder writes first: the replay applies that boundary after the key's own step (since 15/11/2026; before, a revision committed by Return showed as a divergence, day finding 155 of that date) |
| `undoAfterEdit` | Command+Z within 2 s after an engine edit |

Not findings: app substitutions in a readback (curly quotes for straight ones, an ellipsis for three periods, an em
or en dash for hyphens, a period for the first of two spaces); the field then becomes the baseline.

### 2.2 Reading an excerpt

`show N` prints the finding's header, then every line of the window in time order with the time relative to the
finding; `>` marks the finding's own line. Keys print as in the PLT-R905 review window (`key keyDown 0x33 - -
passed`), engine steps with the edit and the token after it, then jobs (`job 12 compose backspaceReplace executed
... 4 events 3.1 ms total`; a job of a rule that reads a selected inline completion through AX, PLT-R420, adds
`completion selected`, `completion none` or `completion unreadable` after the events, since 15/11/2026; a job of a rule
with `forwardDelete`, PLT-R423, adds `completion forwardDelete` (a Forward Delete pair before each Backspace pair: 6
events for a delete-1 edit), `completion forwardDelete skipped notAtEnd`, `completion forwardDelete skipped unreadable`
or `completion selected`), fallbacks, boundaries (`boundary focusChanged / focusChanged`), focus snapshots (bundle,
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
| `file` | `v` format version (3 since 2026-11-15; 2 since the readback timing fields; files of the first day are 1), `launch` ID, `app` version, `build` marker, from version 3 `eng` (engine identity, ADR 0007 decision 13) |
| `start`, `stop` | `launch`, `app`, from version 3 `eng` (start); the recorder started or the app quit |
| `pause`, `resume` | `until` (pause end, microseconds) |
| `settings` | `s`: name to value (typing method, tone placement, English restore, Telex options, macros on and counts, hotkeys, word-list counts, global mode, safe mode) |
| `focus` | `gen`, `bundle`, `role`, `subrole`, `rule`, `strat`, `rtf` (requireTextFocus), `ax`, `secure`, `mode`, `modeSrc`, `ctx` (engine context), `er` (English restore), `mac` (macros), `pause`; from version 3 `front` (NSWorkspace's frontmost application, only when `bundle` is absent; also when the snapshot took that application as its owner because Accessibility named none, PLT-R381, with `rule` the bundle-level rule it resolved to) |
| `key` | `ev` (keyDown, keyUp, flagsChanged, mouseDown), `kc` key code, `fl` CGEventFlags, `ch` layout character, `out` (passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp) |
| `engine` | `act` (passThrough, edit, editThenPassThrough), `del`, `ins`, `comp` token after the key, `dec` commit decision, `rev` revision reason when the commit also revised the previous word (`phrase`, `particleTail`, `nextEnglish`, `nextVietnamese`; PLT-R357). Words of the learned collision memory are never recorded |
| `boundary` | `reason` (the engine's reset reason) and `job` (the boundary job reason); both are `unseenInput` for a keyUp the tap never saw go down (PLT-R397A) |
| `job` | `seq`, `gen`, `kind` (compose, backspaceRecompose, restore, macro, reentry, revision), `strat`, `out`, `delN`, `insN`, `posted`, `totalUs` (from the key), `runUs` (execution), `compl` (only when the job read the inline completion through AX: `selected`, `none` or `unreadable` for PLT-R420; `selected`, `forwardDelete`, `forwardDelete skipped notAtEnd` or `forwardDelete skipped unreadable` for PLT-R423; since 15/11/2026, an optional field, so the format version stays) |
| `fallback` | `seq`, `from`, `to`, `reason` |
| `readback` | `reason` (backspaceEdit, commit, marker), `status` (ok, skippedRule, skippedSecure, skippedNoField, skippedBusy, unavailable, timedOut, failed), `text`, `selLoc`, `selLen`, `bundle`, `rule`; from version 2: `durUs` (the AX calls, timeouts included; absent when none was made), `maxCallUs` (the longest single AX call of the read), `waitUs` (from the first trigger to the read), `idleUs` (time since the last key, click or job when the read started), `overlap` (present and true when a key or click went down while the read was in flight). `t` is when the read started |
| `marker` | `src` (chord, menu) |
| `mode` | `mode`, `manual`, `bundle` |
| `gap` | `reason` (secureInput, secureField, overflow), `end` (microseconds) or `dropped` (records lost); from version 3 `durUs` and, for secureInput, `holder` and `pid` (the likely holder, PLT-R396: the frontmost app may be named when a background process holds secure input) |

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
  markers; the marker chord itself counts as a key) waits for the same pause and gives one read, recorded with the
  most specific reason; while Pa types without a 1 s pause there is no read at all. At most one read per 300 ms. It
  stops between its AX calls if a job starts (`skippedBusy`). It reads through its own AX reference to the app's
  focused element (`skippedNoField` when that is no longer the field of the focus snapshot), so the worker's AX
  element and its messaging timeout stay untouched.
- The explanation of a mismatch names the one character whose absence (or presence) makes the texts agree. When
  later edits deleted across the missing character, several passed keys may fit (the detail counts them); the
  scanner names the first press of a key after its keyUp was held and replayed when one fits (the ADR 0322 hazard,
  in traces written before the fix), else the key a readback was near, else the last one. Read the excerpt before
  trusting the name.
- The first key after a secure gap is not recorded (the gap ends when the main thread handles the resume, after the
  key's tap time), so its keyUp looks orphaned; `unseenKey` ignores keyUps within 1 s after a gap ends.
- Engine identity (format version 3) is a digest over fixed probes: a rule change no probe exercises keeps the same
  identity, and its replay divergences are reported as before.
- When a Backspace reached past what the scanner saw typed, its view is unknown; the next readback it may compare
  gives the baseline back, so later divergences are still found.
- Files of the first day (format version 1) have no readback durations: a readback started before a key counts as
  possibly in flight for up to 150 ms (three AX calls of at most 50 ms), and only `timedOut` readbacks are slow.
- A trace can hold only what the tap and the ax thread saw; text changed by the app itself (autocorrect, completion)
  shows up as an `extraCharacter` or a `readbackMismatch`, not as its own line.

## 5. The readback and WebKit editors

On 2026-11-14, the first day on Pa's Mac, the scanner found two incidents in a native app whose editor is a
WKWebView (no compat rule matched it, so the readback ran): a key the tap passed through never reached the field,
and in both the key went down 27 ms and 71 ms before a commit readback of the first recorder started. That first
pointed at the read racing WebKit, so since then the recorder reads only in a pause.

The traces of 15/11/2026 corrected this (ADR 0007, correction under decision 11): three more drops had no readback
near them, and every lost key was the first press of a key whose previous keyUp the tap had held during an edit and
the worker had replayed as a rebuilt event. The fix is in the pipeline (PLT-R311 amendment, ADR 0322: the keyUp of
a passed keyDown always passes). The readbacks next to the first two drops were coincidence. WebKit editors keep
their readback and the pause rule stays as noise reduction. In a trace written before the fix, a `keyDropped`
whose detail names "the first press of a key after its keyUp was held and replayed" is that bug, not the recorder.

## 6. Builds for invited testers

Since 15/11/2026 (PLT-R904A last item, ADR 0007 amendment "Builds for invited testers") the product owner may give
the development build to testers the product owner invites personally, to collect traces from more people.

1. **Build.** The same Debug configuration, for Apple silicon and Intel
   (`xcodebuild ... -configuration Debug ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64"`), signed with the Apple Development
   identity and never notarized. The bundle is renamed `{{AppName}}-dev.app` and packed with `hdiutil` into a disk
   image holding the app, a link to `/Applications`, the licence texts and the notice
   `packaging/dev-tester/notice.vi.txt` (brand placeholders filled in), which a tester reads before installing.
2. **Before handing it out.** The build must carry the fixes the product owner's own dogfooding found that can hurt a
   tester's Mac, in particular the fail-open on a removed Accessibility grant (PLT-R730): a tester who removes the
   grant while the app runs must keep a working keyboard and mouse.
3. **First launch on a tester's Mac.** macOS refuses to open a build that is not notarized; the tester opens it once
   from System Settings, Privacy & Security, "Open Anyway" (on macOS 12: Control-click the app, then Open), then
   grants the permission the onboarding asks for.
4. **Getting traces.** The tester presses the marker chord right after a problem (not inside a password field: macOS
   hides every key there, the chord included), notes the time, and later sends the hour files of that time from
   "Mở thư mục nhật ký" (for example `20261115-16.jsonl`), after looking at them if they wish. The files hold what the
   tester typed in that hour, so the tester chooses what to send.
   The notice also warns that passwords typed in a terminal (for example at a `sudo` prompt) are not in a secure
   field and may be recorded, so a tester pauses recording first.
5. **Reading them.** `scripts/dev/trace-scan.sh summary --dir <folder with the received files>`, then excerpts only
   around findings, as in section 2.3. Keep received files outside the repository, never commit or forward them, and
   delete them once the problem is understood.
