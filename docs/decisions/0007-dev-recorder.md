# 0007. Dev recorder: an always-on typing log in development builds

- Status: accepted, 2026-11-14 (Pa, the product owner, asked for it after the first day of manual tests)
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
   selection) after a Backspace edit or a commit and at every marker.
5. **Observer rule.** The recorder must not change what {{AppName}} does or what the app sees. Apart from consuming
   its own marker chord it changes no verdict, job or setting. The tap side does no I/O, AX, blocking lock or
   allocation (measured: zero allocations per event with the recorder on). The readback runs on its own queue with
   a 50 ms AX timeout, at most once per 300 ms, never where the compat rule keeps {{AppName}} off accessibility
   (`requireTextFocus: never`, `electron.default`: reading AX attributes there can switch Chromium apps into their
   accessibility mode), never in a secure field or under secure input, and never sets `AXEnhancedUserInterface` or
   `AXManualAccessibility`. It never shares the inject worker's AX element: AX keeps the messaging timeout per
   element object, so the readback asks the app for its focused element again and reads through that new reference
   only when it is still the snapshot's field. It never reads while an edit job is queued or in flight (it waits up
   to 1 s, then records `skippedBusy`), so a worker read never queues behind it on the app's main thread.
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

## Alternatives considered

- **A longer time-boxed capture.** Still has to be started before the bug and reviewed afterwards; it does not fit
  "use it while working and read the logs later".
- **`os_log` with private data shown.** Changes system logging settings on the Mac, mixes with every other process's
  logs, and is harder to purge and to scan offline.
- **A separate recording path.** Duplicates the rings, the drain and the secure-input rules of PLT-R905, and doubles
  the tap's cost.
