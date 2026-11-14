# 0007. Dev recorder: an always-on typing log in development builds

- Status: accepted, 2026-11-14 (Pa, the product owner, asked for it after the first day of manual tests); amended
  the same day after the recorder's first evening on Pa's Mac (decisions 10 and 11, workstream W10-B)
- Spec: PLT-R904A (new, `spec/02-platform.md` section 9, right after PLT-R904); exception to PLT-R901, PLT-R904 and
  PLT-R911 for development builds only. Related: PLT-R304, PLT-R305, PLT-R905, PLT-R903, PLT-R343, PLT-R386.
- Runbook: [dev-recorder.md](../runbooks/dev-recorder.md).

## Context

Pa dogfoods {{AppName}} while working. On 2026-11-14 several typing bugs showed up while Pa was busy (the manual-test
feedback of that day, items 2, 3, 7, 8 and 9: Backspace, late focus changes, Spotlight); when Pa came back to them
later, they could not be reproduced. The time-boxed capture (PLT-R905) does not help here: it has to be started
before the bug, it stops after at most 180 s, and the user must be ready to review it.

On 2026-11-14 the product owner asked for a debug build to use every day that records all typing, so that the
bugs met during the day can be read from the log afterwards.

PLT-R904 forbids any verbose or debug mode that logs content. Its rationale is the prior art's debug mode: it wrote
keystroke-level content to a plain file in the home folder, never deleted it, and users were asked to paste the file
into public issues.

## Decision

1. **Development builds only.** A dev recorder exists only in builds of the Debug configuration: the ones signed
   with the development bundle ID and the Apple Development identity, never notarized, never distributed and never
   built by `scripts/build-release.sh`. It is compiled under one condition, `DEV_RECORDER`, defined only for Debug:
   `.define("DEV_RECORDER", .when(configuration: .debug))` on the AppCore targets that need it and
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) DEV_RECORDER` for the App target's Debug configuration in
   `project.yml`. Release and Integration also exclude every `*DevRecorder*` file by name
   (`EXCLUDED_SOURCE_FILE_NAMES`), the DevRecorder string table included.
2. **Absent from releases by construction, and checked.** `scripts/verify-release.sh` fails a bundle in which any
   file contains the recorder's marker string (`DevRecorder.buildMarker`, written into every trace file header so
   the optimizer keeps it) or which has a `DevRecorder.strings` table. A Release build of the App was checked when
   this landed: no marker, no recorder symbol, no string table; the Debug build has all three.
3. **One recording path.** The recorder extends the PLT-R905 capture instead of adding a second path: the tap, the
   inject thread and the ax thread push into the capture's SPSC rings (plus three dev rings for the extra records),
   the same 2 s drain on the utility queue writes them, and the capture's secure-input and secure-field gaps apply.
   A time-boxed capture keeps working unchanged beside it.
4. **What is recorded**, beyond PLT-R905's keys, edits, jobs and focus snapshots: every engine decision with the
   token's display after it, every hard boundary with its reasons, every edit job (kind, strategy, outcome, events
   posted, durations) and fallback with its reason, VI/EN changes, a settings snapshot (engine-affecting values,
   word lists and macros as counts only) at the top of each file and on every change, focus snapshots with the
   compat rule and decision (never titles or URLs), and a field readback (64 UTF-16 units before the caret and the
   selection) at the first typing pause after a Backspace edit, a commit or a marker (decision 10).
5. **Observer rule.** The recorder must not change what {{AppName}} does or what the app sees. Apart from consuming
   its own marker chord it changes no verdict, job or setting. The tap side does no I/O, AX, blocking lock or
   allocation (measured: zero allocations per event with the recorder on). The readback runs on its own queue with
   a 50 ms AX timeout, only in a typing pause (decision 10), at most once per 300 ms, never where the compat rule
   keeps {{AppName}} off accessibility
   (`requireTextFocus: never`, `electron.default`: reading AX attributes there can switch Chromium apps into their
   accessibility mode), never in a secure field or under secure input, and never sets `AXEnhancedUserInterface` or
   `AXManualAccessibility`. It never shares the inject worker's AX element: AX keeps the messaging timeout per
   element object, so the readback asks the app for its focused element again and reads through that new reference
   only when it is still the snapshot's field. It never reads while an edit job is queued or in flight (a job
   postpones it like a key, and a job starting between its AX calls stops it with `skippedBusy`), so a worker read
   never queues behind it on the app's main thread.
6. **Storage and retention.** `~/Library/Logs/{{AppName}}/dev-traces/YYYYMMDD-HH.jsonl`, one file per local hour,
   folder 0700, files 0600, both excluded from backups; deleted after 7 days and kept under 200 MB in total, oldest
   first; purged at launch and hourly.
7. **Visible and controllable.** Always on from launch, without a confirmation (Pa asked for exactly that). A
   persistent dot on the menu bar icon (also in its VoiceOver label) while recording; menu items for the state,
   "Tạm dừng ghi 30 phút" / "Tiếp tục ghi", "Đánh dấu lỗi vừa gặp" and "Mở thư mục nhật ký" (DevRecorder string
   table, vi and en, VoiceOver hints).
8. **Marker chord: Control+Option+Command+Semicolon.** The first idea, Control+Option+Command+B, is VoiceOver's
   documented "find next bold text" (VO-Command-B, Apple's VoiceOver User Guide, search commands). VoiceOver leaves
   Semicolon unmapped at that level (VoiceOver command charts) and Apple's "Mac keyboard shortcuts" document no
   shortcut on it; a missed modifier types `;`, `…` or runs "check spelling", none of which loses text (unlike
   Command+Z or Command+R). The chord is consumed by the tap in development builds only, its key-up too, and gives
   a 1 s flash of the icon plus a VoiceOver announcement; it never opens a window or takes focus.
9. **Nothing leaves the Mac.** The recorder uploads nothing. The only reader is the offline scanner `trace-scan`
   (`swift run --package-path Packages/AppCore -c release trace-scan`, or `scripts/dev/trace-scan.sh`), which never
   writes anywhere but standard output. Its `summary` prints metadata only (files, apps, counts, gaps, findings with
   time, app, rule and kind); `show N` prints the excerpt around one finding, which is the only typed content the
   integrator reads.

10. **Readback only in a typing pause** (amendment, 2026-11-14 evening). The first recorder read about 300 ms after
    a commit or a Backspace edit and at once for a marker, without holding keys. Its first evening on Pa's Mac gave
    two incidents in a native app whose editor is a WKWebView (no compat rule matched, so AX was allowed): a key the
    tap passed through never reached the field. In incident 1 the next word's first key went down 273 ms after the
    commit and 27 ms before the commit readback started, which read the field without it; from then on the field
    had one character fewer than {{AppName}} believed, and the scanner reported one mismatch and five follow-ons. In
    incident 10 three keys passed 64 to 70 ms apart, the commit readback of the previous word started 71 ms after
    the last of them, read the field without it, and the field never received it. The Mac was under heavy memory
    pressure. The likely cause is an accessibility read of a large WebKit editor (its focused element, selection
    and text) racing a keystroke WebKit is still handling. Production {{AppName}} holds keys while a job touches AX
    (PLT-R311), so it never races this way; an observer must not hold keys. So:
    - Every readback (commit, Backspace edit, marker; the marker chord counts as a key) waits until no key or
      click has gone down and no edit job has run for **1 s** (`DevReadback.quietPeriod`): twice PLT-R382's
      500 ms, the spec's bound of continuous typing, so a pause that long is neither between two keys of a word
      nor between two words typed in a row (incident 10: 64 to 70 ms between keys, 95 ms from the space to the
      next word, 300 ms commit delay), and a key the app was still handling has long arrived. It is short enough
      that most pauses to read or think still get a read. Every trigger since the last read gives one read with the most specific reason; while Pa types
      without such a pause there is none. The tap tells the recorder the time of every key and click down (two
      atomic writes, no allocation); the inject thread the end of every job.
    - A key or click that still goes down while the read is in flight is flagged on the line (`overlap`), and the
      scanner does not compare such a read. Each line also records the AX calls' duration (`durUs`, timeouts
      included) and the longest single call (`maxCallUs`), the wait since the first trigger (`waitUs`) and the
      input's idle time when the read started (`idleUs`). File format version 2.
    - The scanner explains a mismatch that is exactly one passed key missing from the field (`keyDropped`) or one
      character more in the field (`extraCharacter`), says whether a readback was in flight when that key went down
      or started within 200 ms after it, takes the field's text as its new baseline after any mismatch (one
      divergence, one finding), and flags readbacks that timed out or one of whose AX calls took more than 30 ms,
      the inject worker's per-call timeout (`slowReadback`). The summary names no character; `show` does, in the
      finding's note.
    The incidents are reproduced with sample words in `Packages/AppCore/Tests/TraceScanTests/Fixtures/incidents`.

11. **WebKit editors keep their readback.** Skipping them until proven safe was considered and rejected:
    - The evidence points at timing, not at reading WebKit as such: in both incidents the lost key went down 27 and
      71 ms before a read started. {{AppName}} already reads WebKit fields while typing goes on, but with the keys
      held (PLT-R311): the Safari address bar rule reads `AXSelectedTextRange` before it deletes (`inlineCompletion:
      axSelection`), and the re-entry verification (PLT-R342) and the late focus check (PLT-R340) read a bounded
      range before the caret. Decision 10 gives the observer the same condition without holding keys: no key is on
      its way to the app when a read starts.
    - The readback is what lets the trace explain a bug, and Pa wants the log to explain bugs. Both incidents came
      from a web editor in a native app; without a readback there, the scanner would have seen nothing wrong.
      Electron apps are already excluded by their rule.
    - Telling a WebKit editor apart would take more AX traffic (a walk up to an `AXWebArea`): the focused element's
      role alone (`AXTextArea`) does not distinguish it from an AppKit text view.
    Revisit as soon as a version 2 trace shows a `keyDropped` whose detail names a readback in flight when the key
    went down or started right after it: then skip the readback in fields inside a web area (the focus record
    gains that flag) and amend this decision. A `keyDropped` with no readback near it is not the observer's doing.

## Why PLT-R904's rationale does not apply

| PLT-R904's concern (prior art) | The dev recorder |
|---|---|
| Debug mode in the shipped product, switchable by any user | Not compiled into releases at all; the release check fails a bundle that contains it |
| A plain file in the home folder | 0600 files in a 0700 folder under `~/Library/Logs`, excluded from backups |
| Never deleted | Deleted after 7 days, 200 MB cap, purged hourly |
| Users asked to paste it into public issues | Only on the product owner's own development Mac; nothing reads it but a local scanner that prints metadata and short excerpts around findings |
| Recording without the user noticing | Always visible: a dot on the menu bar icon, a status line, pause and resume |

## Consequences

- Development builds now hold typed content on disk for up to 7 days. That is acceptable only because the product
  owner asked for it, the builds are his own, and the files never leave the Mac.
- Debug builds run the drain every 2 s and the hourly purge (PLT-R803 applies to shipped builds; a development build
  may wake more often).
- Two shared low-level fixes came with it: `InlineUTF16.init(_:)` no longer allocates per event in unoptimised
  builds (a `for ... in` over a range did), and the recorder boxes the closures it reads through `Mutex.withLock`
  (reading a bare function value that way re-wraps it in a thunk on every call).
- The scanner reads the format documented in the runbook; a round-trip test writes with the recorder and reads with
  the scanner, so the two cannot drift.
- Since decision 10 a readback can come many seconds after its trigger (Pa typing on), and a fast typist gets fewer
  readbacks than before. The scanner compares at the time of the read, so a late read is still compared with what
  {{AppName}} believed at that moment.

## Alternatives considered

- **A longer time-boxed capture.** Still has to be started before the bug and reviewed afterwards; it does not fit
  "use it while working and read the logs later".
- **`os_log` with private data shown.** Changes system logging settings on the Mac, mixes with every other process's
  logs, and is harder to purge and to scan offline.
- **A separate recording path.** Duplicates the rings, the drain and the secure-input rules of PLT-R905, and doubles
  the tap's cost.
