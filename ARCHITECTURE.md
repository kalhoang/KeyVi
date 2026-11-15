# Architecture

This document is the map of the macOS platform layer: which module does what, which thread runs it, how one
key press becomes text in another app, and where per-app behaviour, settings, diagnostics and updates live
(QA-R66). It is written for contributors. The normative source is `spec/`; requirement IDs
(PLT-R, PRD-R, QA-R, CLR-R, ENG-R) point there. Detailed Swift contracts are in
[docs/architecture/contracts.md](docs/architecture/contracts.md), the requirement map in
[docs/architecture/traceability.md](docs/architecture/traceability.md) and the build plan in
[docs/architecture/workstreams.md](docs/architecture/workstreams.md). Decisions are recorded in
`docs/decisions/03xx-*.md`.

Code reads the product name from the bundle (`Brand`, ShellCore); this document says "the app".

## 1. Shape of the system

One long-lived menu-bar process (`LSUIElement`), no daemons, no extensions, no IMKit bundle in v1 (PLT-R201,
PLT-R206). If the process dies, macOS removes its event tap and the keyboard keeps working (PLT-R204).

```
 physical key ─▶ HID / remappers ─▶ WindowServer ─▶ session event tap (head insert) ─▶ other consumers ─▶ focused app
                                                     │                    ▲
                                                     │ swallow + job      │ synthetic events (marked, session level)
                                                     ▼                    │
                                              injection queue ─▶ inject worker
```

The app transforms keys before other session-level consumers (text expanders, automation tools), and its own
synthetic events pass back through its tap, which gives a delivery confirmation ("echo", PLT-R301, PLT-R323).

## 2. Module map

```
                         ┌────────────────────────── App (XcodeGen target "App") ───────────────────────────┐
                         │ Composition root · status item + menu · HUDs · Settings (5 panes) · onboarding · │
                         │ macros editor · Apps pane · bug report · diagnostics window · Sparkle wrapper    │
                         └───────────────┬──────────────────────────────────────────────────┬───────────────┘
                                         │                                                  │
        Packages/AppCore                 ▼                                                  ▼
   ┌───────────┐   ┌──────────────────────────────────────────────┐                   ┌───────────┐
   │ ShellCore │──▶│ InputHost                                    │◀── VietnameseEngine│  Sparkle  │
   └─────┬─────┘   │ snapshots · engine bridge · pipeline · tap   │    (+ EngineData)  │ (2.10.1)  │
         │         │ lifecycle · hotkeys · input source · secure  │                   └───────────┘
         │         │ input · focus (AX) · per-app memory · perms  │
         │         └──┬──────────┬───────────┬───────────┬────────┘
         │            ▼          ▼           ▼           ▼
         │      ┌──────────┐ ┌───────────┐ ┌──────────────┐ ┌─────────────┐
         └─────▶│Injection │ │CompatRules│ │SettingsStore │ │ Diagnostics │
                └────┬─────┘ └─────┬─────┘ └──────┬───────┘ └──────┬──────┘
                     ▼             ▼              ▼                ▼
                ┌─────────────────────────────────────────────────────────┐
                │ AppModel (vocabulary) · RealtimeSupport (lock-free kit) │
                └─────────────────────────────────────────────────────────┘
   TestSupport (fakes, harness) ─▶ everything above except App;  compat-harness / compat-lint executables
```

| Module | Owns | Must not |
|---|---|---|
| `AppModel` | Validated identifiers (`BundleKey`, `RuleID`, `InputSourceID`, `KeyCode`), enums whose raw values are JSON spellings, `HotkeyBinding`, `LooseVersion`, `JSONValue`, host-state vocabulary, `FileSystem` | Contain behaviour |
| `RealtimeSupport` | `SnapshotCell` + `ReaderEpoch`, `SPSCRing`, `WakeSignal`, `WorkerSignal`, `MachClock`, `TimerScheduler`, `AtomicUInt64Array`, `InlineUTF16`, `ThreadConfined`, `RunLoopThread` | Depend on anything app-specific |
| `Diagnostics` | Typed redacting logger, health events, histograms, tap log ring, environment report and issue block, time-boxed capture, signposts | Accept free-form strings |
| `SettingsStore` | Four JSON documents, unset-vs-set model, migrations, backups, corruption recovery, export/import, macro importers, crash-loop guard | Know about AppKit, rules or the engine |
| `CompatRules` | Rule schema (5.4), loader with embedded fallback, matcher (5.5), engine fingerprinter, matrix model, linter | Contain bundle IDs in code (PLT-R501) |
| `Injection` | Job model, FIFO queue, inject worker, strategies, inline completion, pasteboard preservation, CoreGraphics/AX/pasteboard services | Read rule JSON or snapshots |
| `InputHost` | Tap thread and decision pipeline, engine bridge, snapshots, lifecycle state machine (`HostLifecycle`, a pure value) and its owner `InputHostController`, hotkeys, layout tables, input sources, secure input, focus tracking on the ax thread, per-app memory, permissions, workspace events, probes | Branch on bundle IDs |
| `ShellCore` | UI-free shell logic: `Brand`, `Localizer`, pane-name table, icon/menu/status models, onboarding flow, app-location check, report assembly, bug report URLs, Apps pane model, login item, updater protocol | Import AppKit or SwiftUI |
| `App` | Views and controllers, composition root, Sparkle wrapper | Contain logic that ShellCore can hold |
| `TestSupport` | Fakes for every platform service, simulated text field, window-server queue model, manual scheduler, deterministic pipeline harness, conservation ledger, seeded generators, scenario runner | Ship in the app |

Why these targets and not exactly the PLT-R102 list: [0302](docs/decisions/0302-package-and-target-split.md).

## 3. Process and thread model

Normative thread map (PLT-R203), with the type that owns each thread:

| Thread | QoS / run loop | Owner type | Does | Never does | Talks to others through |
|---|---|---|---|---|---|
| main | user-interactive, AppKit | `InputHostController` (`@MainActor`), App controllers, `InputSourceMonitor` | UI, NSWorkspace and TIS notifications, layout-table builds, lifecycle state machine, Sparkle UI | Per-keystroke work | Publishes `InputSourceSnapshot`, `LifecycleSnapshot`; drains the tap -> main outbox |
| `tap` | user-interactive, dedicated `Thread`, CFRunLoop with only the tap source (PLT-R303) | `TapThread`, `KeyPipeline` | The PLT-R304 list: read event fields, one atomic load per snapshot, layout table lookups, one engine call, lock-free pushes, atomic counters, histogram increments, fixed-size log records | AX, I/O, blocking logs, sleeps, waits, contended locks, `DispatchQueue.sync`, async/await, AppKit, TIS, NSWorkspace, pasteboard (PLT-R305) | `JobQueue` (SPSC + semaphore signal), outboxes (SPSC + `WakeSignal`), atomics |
| `inject` | user-interactive, dedicated `Thread`, no run loop, semaphore-driven loop | `InjectionWorker` | Posts synthetic events, pacing with absolute deadlines, bounded AX reads/writes for injection, pasteboard snapshot/restore | Wait on main or tap (PLT-R315), unbounded waits | `WorkerFeedback` and `EchoTracker` atomics |
| `ax` | user-initiated, dedicated `RunLoopThread` with AXObserver sources | `FocusTracker` | All focus-tracking AX calls, rule resolution, engine fingerprinting, per-app memory | Post events, file I/O beyond cached reads | Publishes `FocusSnapshot` and `CurrentFocusGeneration`; drains the tap -> ax outbox |
| utility | utility, GCD serial queue | `SettingsStore` (actor on this queue), `DiagnosticsLogger`, `SecureInputMonitor`, `PermissionMonitor`, `TapWatchdog` | Log draining and writing, settings persistence, secure-input polling, watchdogs, report generation, engine catalog builds | Hot-path work | Publishes `TapSettingsSnapshot`, `SecureInputSnapshot` |

Swift 6 strict concurrency: main-thread types are `@MainActor`; the settings store is an `actor` whose
executor is the utility `DispatchSerialQueue`; everything that crosses threads is `Sendable`. Swift cannot
express "owned by this run-loop thread", so the tap and ax state lives in `ThreadConfined` (debug-checked) or
in non-Sendable objects created on and touched only by their thread. Those two patterns are the only audited
escape hatches. Concretely for the tap: `TapThread<Handler: TapEventHandler>` receives a `@Sendable` factory,
calls it inside its own thread entry and keeps the resulting `KeyPipeline` (not Sendable on purpose) in that
thread's state, reached from the C callback's `userInfo`; the pipeline never leaves the tap thread and no
per-callback check runs ([0313](docs/decisions/0313-testability-seams.md)). Sparkle's delegate methods are
`nonisolated` and use `MainActor.assumeIsolated` (Sparkle calls them on the main thread). Every periodic or
delayed action off the hot path goes through an injected `TimerScheduler` and every service clock is
`any MonotonicClock`, so tests drive them with `ManualScheduler`/`ManualClock`.

## 4. The life of one key press

Example: Telex user types `a` then `s` in a native text field; the engine answers `edit(delete 1, insert "á")`.

1. **Tap callback** (`TapThread` C callback -> `KeyPipeline.handle`). It enters the reader epoch and the
   callback watchdog, copies the needed `CGEvent` fields into a `RawKeyEvent` (`keyCode`,
   `CGEventFlags`, `kCGKeyboardEventAutorepeat`, `kCGKeyboardEventKeyboardType`, `kCGEventSourceUserData`,
   `CGEventKeyboardGetUnicodeString`) and runs the decision pipeline (PLT-R310):

   | Step | What | Where |
   |---|---|---|
   | 1 | `tapDisabledByTimeout` / `ByUserInput`: re-enable if permissions are still valid, reset, flush held events, log, count (PLT-R330). Then `EchoTracker.settle(now:)`: settle jobs whose echo came back or timed out; three consecutive misses fail open in this callback (PLT-R323, PLT-R730) | `KeyPipeline`, `TapThread`, `EchoTracker` |
   | 2 | Marker check: an echo of our own event settles its job in `EchoTracker` and is passed unchanged; a probe-tagged event is processed as physical with probe metrics (PLT-R321, PLT-R323, PLT-R810) | `EventMarker.classify` |
   | 3 | Mouse down: hard boundary, pass, never held (PLT-R317). Scroll wheel (in the mask by default because PRD-R14 cancels the toggle tap on scroll): only `HotkeyRecognizer.handle(.scroll)`, then pass (PLT-R301) | pipeline |
   | 4 | Load the five snapshots: settings, focus, input source, secure input, lifecycle (one atomic load each) | `TapSnapshots` |
   | 5 | Hotkeys: toggle tap fires on release when nothing else happened within 500 ms; combos consume down and up; the restore binding asks the engine (PRD-R14-R18, PLT-R353) | `HotkeyRecognizer` |
   | 6 | `HostStateResolver`: paused, fail-open, EN mode or `passThrough` strategy means "pass" without feeding the engine; a key reaching the tap while paused for secure input resumes immediately (PLT-R398B) | pipeline |
   | 7 | Classify with the precomputed `UCKeyTranslate` table: character, backspace, navigation, Escape, Return/Tab, Command/Control chord, Option chord, dead key, function key (PLT-R350-R356, PLT-R360) | `KeyClassifier`, `LayoutTable` |
   | 8 | Feed the engine once: `.key`, `.backspace`, `.restoreToggle` or `.reset` | `CompositionEngine` |
   | 9-10 | Map to an outcome and return: pass (event returned unchanged), or swallow (return NULL) and push an `EditJob`, `ReplayJob`, `pairedKeyUp` or `BoundaryJob` | `JobQueue.push` |

   For `s` the engine returns an edit, so the tap returns NULL, records the consumed keyDown in its fixed
   keyUp table and pushes an `EditJob` (strategy and parameters from the focus snapshot, deleteCount 1,
   insertion "á", trigger keycode, focus generation, a copy of the trigger for conservation). The whole
   callback targets p50 15 µs, p99 60 µs (T1).
2. **Hold while busy** (PLT-R311). While the job is in flight (`JobQueue.inFlight > 0`), every keyboard event
   the pipeline would pass is swallowed and queued as a `ReplayJob` (a bitwise copy of keycode, flags,
   autorepeat, keyboard type and Unicode string, PLT-R324). "In flight" lasts until the tap sees the echo of
   the job's last event (or 200 ms pass without it), not merely until the worker posted it: a physical key that
   reached the WindowServer before the post is ahead of the synthetic events in the server's queue, reaches the
   tap before their echo, and is held instead of overtaking them
   ([0311](docs/decisions/0311-in-flight-until-echo.md)). A fast typist's next key therefore can never land
   between the backspace and the "á".
3. **Inject worker** pops the job (FIFO), checks the focus generation (stale edits are discarded and their
   triggers replayed, PLT-R316, [0308](docs/decisions/0308-conservation-on-abandoned-edits.md)), trims the
   common grapheme prefix (PLT-R402), applies inline-completion handling if the rule says so (PLT-R420-R422),
   then posts through `EventPoster`: one backspace pair (`kVK_Delete`, no Unicode), then one keyDown/keyUp pair
   carrying "á" via `CGEventKeyboardSetUnicodeString` with the trigger's keycode (PLT-R404-R407). Events come
   from a `privateState` `CGEventSource` with suppression interval 0, explicit flags, `kCGEventSourceUserData`
   = per-launch 40-bit random tag + sequence, posted at `kCGSessionEventTap` (PLT-R320-R322). Then the held
   events are replayed in order. Target: decide-to-posted p50 0.5 ms, p99 2 ms (T2).
4. **Echo.** The synthetic events pass back through the tap. After posting a job's last event the worker
   publishes an `EchoExpectation` (job, event sequence, time); the tap settles the job when the echo arrives,
   which ends "in flight". If three consecutive jobs see no echo within 200 ms, the tap fails open in the same
   callback and marks posting broken; the first miss asks the utility queue to check
   `CGPreflightPostEventAccess()` (PLT-R323, PLT-R730). If PLT-R301 VERIFY (a) shows that echoes do not come
   back, `JobQueue(policy: .untilPosted)` restores the literal reading and echo liveness is dropped as the spec
   instructs.
5. **Liveness.** If the oldest held event waits more than 150 ms (1 s during a macro) or more than 256 jobs
   queue up, the worker abandons unstarted edits (replaying their triggers), replays all held events in
   order, asks the tap to reset the composition and records a `flush` (PLT-R314).

**Conservation invariant (PLT-R312).** While posting works, every physical keyboard event ends in exactly one
of: passed unchanged; replayed once after all earlier jobs; consumed as an engine trigger whose effect an
`EditJob` delivers (or, if that job is abandoned, replayed); consumed as the keyUp of such a trigger; consumed
as a hotkey. Nothing is dropped or delivered twice. When posting breaks silently (permission revoked:
`CGEventPost` reports nothing), events whose replay or edit falls into the detection window (at most three jobs
times 200 ms) cannot be delivered, because a replay is also a post; they are lost on purpose rather than
blocking the keyboard, counted in `lostWhilePostingBroken` and reported in one `postingBroken` health event
([0308](docs/decisions/0308-conservation-on-abandoned-edits.md)). `ConservationLedger` (TestSupport) checks the
invariant and the counted losses over 100,000 random interleavings of keys, mouse downs, focus changes,
tap-disabled events, secure-input toggles, permission changes and window-server queue lag (13.1).

**Boundaries.** Space and punctuation are soft boundaries handled inside the engine (history kept, PLT-R341).
Hard boundaries (focus change, mouse down, navigation, Command/Control chords, Return/Tab after commit,
passed-through Escape, input-source change, VI/EN toggle, secure-input transitions, tap re-enable, flush,
sleep/wake/lock/session switch, permission change, rule or strategy change, engine-affecting settings changes)
reset the engine (PLT-R340, ENG-R1010) and enqueue a `BoundaryJob` when jobs are in flight.

## 5. Host state machine (02-platform.md 2.1)

States: `noPermission`, `starting`, `ready(vi|en)`, `paused(reason)`, `failOpen(reason)`.

```
            launch
              │
              ▼
        ┌──────────┐ permission granted, tap created  ┌──────────────┐
        │ starting │─────────────────────────────────▶│ ready(mode)  │◀──────────────┐
        └────┬─────┘                                   └──┬────────┬──┘               │
   no permission                         pause signal   │        │ posting broken /    │ signal cleared
             ▼                           (per key)      ▼        │ trust revoked /     │ (first key after
      ┌──────────────┐                        ┌────────────────┐ │ tap nil / watchdog  │  secure input:
      │ noPermission │                        │ paused(reason) │─┼─────────────────────┘  immediately)
      └──────┬───────┘                        └────────────────┘ ▼
             │ granted (poll 2 s / 1 s in onboarding)    ┌──────────────────┐
             └──────────────────────────────────────────▶│ failOpen(reason) │── permission back / backoff
                                                         └──────────────────┘   1,2,5,10 s ─▶ starting
```

- Pause reasons are evaluated per key by `HostStateResolver` from snapshots, with precedence lifecycle >
  sessionInactive > diagnosticsTest > userDisabled > secureInput > secureField > builtInVietnameseSource >
  nonLatinInputSource > passThroughRule > noTextFocus. The main thread runs the same function for the icon and
  menu (PRD-R10, PRD-R11), so what the user sees is what the tap does. `diagnosticsTest` is the guided test's
  pass-through (PLT-R1205): every key passes unchanged and hotkeys are suspended while the test types.
- Lifecycle phases (`noPermission`, `starting`, `running`, `sessionInactive`, `failOpen`) are decided by the
  pure state machine `HostLifecycle` (inputs: permission changes, tap created or failed, retry timer, watchdog
  trips, posting broken, session events; outputs: effects) and published as `LifecycleSnapshot` by its owner
  `InputHostController`, which performs the effects and owns the timers.
- Every transition into or out of `paused`/`failOpen`, and every focus change, resets the composition
  (PLT-R210).
- Fail-open (PLT-R730): the tap stops swallowing within the same callback (it reads the echo result,
  `WorkerFeedback.isPostingBroken` and the lifecycle phase at entry), the worker replays held events if posting
  still works (otherwise counts them as lost), the composition resets, then the tap is disabled and removed.
  Recovery recreates it without relaunch (PLT-R731). Tap creation failure retries with backoff 1, 2, 5, 10 s
  while permissions look granted (PLT-R332).
- Watchdog (PLT-R306, [0309](docs/decisions/0309-callback-watchdog-gating.md)): a callback over 250 ms disables
  the tap and enters `failOpen(watchdog)`; recovery 2 s later happens only if the callback has returned. If it
  never returns, the host stays in `failOpen(callbackStuck)` with a "reopen the app" status line and never
  creates a second tap or tap thread.

## 6. Snapshot publication (PLT-R388)

Writers publish immutable values; the tap reads each with one atomic load. Implementation in Swift 6 with the
`Atomic` and `Mutex` of `RealtimeSupport`, which mirror the `Synchronization` module (macOS 15 only) on the macOS 12
floor ([0303](docs/decisions/0303-snapshot-publication.md), [0315](docs/decisions/0315-minimum-macos-12.md)):

```swift
// RealtimeSupport/SnapshotCell.swift (abridged)
public final class SnapshotCell<Value: Sendable>: Sendable {
    private let current: Atomic<Unmanaged<Box>>      // +1 retained box
    private let writer: Mutex<WriterState>           // retired boxes, latest value (writers only)
    private let epoch: ReaderEpoch                   // tap callback enter/exit counter

    public func read<R>(_ body: (Value) -> R) -> R { // tap thread, inside enter()/exit()
        current.load(ordering: .sequentiallyConsistent)._withUnsafeGuaranteedRef { body($0.value) }
    }
    public func publish(_ value: Value)              // main / ax / utility: exchange + QSBR reclaim
    public func load() -> Value                      // other readers: short lock, strong copy
}
```

Why it never blocks the tap: the tap's path is two atomic increments of `ReaderEpoch` per callback and one
atomic load per cell. It never retains, never takes a lock and never frees memory. A replaced box is released
by a writer only after the epoch proves the tap has left every callback that could have loaded it.

Snapshots and their writers: `TapSettingsSnapshot` (utility, after a settings change; contains the prebuilt
engine catalog and hotkeys), `FocusSnapshot` (ax, on focus change; resolved rule as an `InjectionPlan`,
engine variant, text-focus gating, per-app mode, AX field handle), `InputSourceSnapshot` (main, on
`kTISNotifySelectedKeyboardInputSourceChanged`; layout table), `SecureInputSnapshot` (utility poller),
`LifecycleSnapshot` (main state machine). A mode change caused by focus change is in the focus snapshot
before the next key is processed (PLT-R391).

## 7. Per-app behaviour lives in data

- **No per-app branches in code** (PLT-R501). Bundle IDs appear only in `compat/rules.json` (shipped as
  `compat-rules.json`), test fixtures, `compat/matrix.json` and the conflicting-apps list inside the rules
  file (each of its bundle IDs records where it was read in `compat/conflicting-apps.json`, PLT-R399). A CI lint fails on bundle-ID-shaped literals elsewhere; reverse-DNS constants that are not bundle IDs
  (pasteboard types, distributed notification names) live only in files named `ReverseDNSConstants.swift`,
  and each one is allowed by a pattern in `scripts/lint-bundle-ids.allow` or an inline
  `lint:allow-bundle-id <reason>` marker (ADR 0505).
- **Rules** follow the 5.4 schema (`CompatRules/Schema.swift`, `compat/schema/rules.schema.json`). The loader
  validates at launch; an invalid file never crashes the app and falls back to a compiled-in ruleset that has
  only defaults and engine-level rules (PLT-R503). No remote rules (PLT-R504).
- **Resolution** runs on the ax thread on focus change only (PLT-R523): candidates are rules whose present
  match fields all match; specificity scores per PLT-R520; user overrides always outrank shipped rules
  (PLT-R522); ties resolve to the smaller id with a health event (PLT-R521). The winning action is applied over
  `defaults`, then converted once into the tap's `HostDecision` (`InjectionPlan`, engine variant, concrete
  `requireTextFocus`, features).
- **Engine fingerprint** (`EngineFingerprinter`, cached per bundle path and `CFBundleVersion`) classifies apps
  as electron, chromium, cef, gecko, jvm, qt, catalyst, ios, webkitBrowser (from the rules group
  `webkitBrowsers`) or native, so a new Chromium browser gets Chromium rules without an update (PLT-R510).
- **Focus authority** is the system-wide AX focused application and element (PLT-R381), so Spotlight,
  Raycast and Alfred panels get their own rules and memory; AXObservers watch the focused app and apps with
  `overlay: true` (PLT-R380). AX calls use a 100 ms messaging timeout and a per-pid circuit breaker
  (PLT-R384).
- **Per-app VI/EN memory** (`AppModeMemory`, ax-thread value, persisted in `app-modes.json`): precedence
  ignore > always English > always Vietnamese > remembered > rule `defaultMode`/D13 > global mode (PRD-R21).
  Toggles happen on the tap: it flips the mode immediately, tags the toggle with a sequence number and tells
  the ax thread; the focus snapshot carries the highest toggle sequence the ax thread has applied, so the tap
  uses its own toggle until the snapshot catches up. No race can flip the mode back.
- **User overrides** (`rule-overrides.json`) come from the guided test, the Apps pane's "compatibility mode"
  (at most three plain choices, PRD-R36) or imported rule JSON; they take effect on the next keystroke
  (PLT-R540).

## 8. Keyboard layouts and input sources

- The engine consumes characters, not keycodes. On every input-source change the main thread builds (or
  reuses) a 128 x 4 table with `UCKeyTranslate` over the layout's `uchr` data for none, Shift, Caps Lock and
  Shift+Caps Lock, plus a reverse map used for restore/macro keycodes and the paste "v" (PLT-R360, PLT-R405).
  QWERTZ, AZERTY, Dvorak and Colemak work because letters are what the layout produces (PLT-R361).
- Only ASCII-capable keyboard layouts are transformed. Input methods, input modes and non-ASCII layouts pause
  with the source's name (PLT-R371); a macOS built-in Vietnamese source pauses with an explanation
  (PLT-R372), detected by source language and kind rather than by ID literal. The optional layout binding
  (PLT-R373) maps designated layouts to VI or EN.

## 9. Secure input (P0-1)

- Only two signals pause for security: the OS secure-input state (`IsSecureEventInputEnabled()`, polled every
  2 s and on menu open) and focus on an `AXSecureTextField` (PLT-R398A). No heuristics.
- The likely holder comes from the IORegistry root's `IOConsoleUsers` entry for the console session
  (`kCGSSessionSecureInputPID`), mapped to an app name; `loginwindow` (recognised by process name) and dead PIDs
  get "lock and unlock the screen" advice (PLT-R396). Hints such as iTerm2's automatic secure keyboard entry
  are data (`secureInputHints` in the rules file) with copy in the `Status` string table (PLT-R397,
  PLT-R398C).
- Resume without delay (PLT-R398B): any regular keyDown that reaches the tap while paused proves secure input
  is no longer blocking; the tap leaves the pause for that snapshot generation, processes the key normally
  (fresh composition) and notifies main. The generation changes on OS transitions, so a stuck OS flag cannot
  re-pause a working keyboard; and key evidence ends the episode, so the next poll that still sees the flag on
  starts a new generation (on, off, key, on again inside one 2 s poll interval pauses again instead of showing
  "ready" while the OS blocks keys).
- The app never calls `EnableSecureEventInput` (PLT-R398). Spike S1 (`SpikeIMK`) measures whether an IMKit
  input source still receives keys in terminals under secure keyboard entry (PLT-R398D); Pa runs it by hand.

## 10. Injection strategies

Strategy code is generic; which one runs is data (section 7). `backspaceReplace` is the default;
`selectReplace` uses Shift+Left; `axReplace` sets `AXSelectedTextRange` then `AXSelectedText` with mandatory
bounded readback; `paste` is opt-in, preserves every pasteboard item and type, marks its item transient,
concealed and auto-generated, and restores only if `changeCount` is unchanged (PLT-R461); `passThrough`
builds no jobs. Inline completion handling (`axSelection`, `placeholder`, `axSelectionThenPlaceholder`)
removes the selected suggestion before the first backspace (PLT-R420-R422); `forwardDelete` clears a suggestion
shown after the caret without a selection with a Forward Delete before each backspace, only when one bounded AX read
finds the caret at the end of the text (PLT-R423). Timing parameters are capped at
50 ms each; pacing waits use absolute mach deadlines on the inject thread (PLT-R408, PLT-R409). Forward
delete deletes no text: it is emitted only by `forwardDelete`, never by default, and only in rules scoped to apps or
fields (PLT-R407 as amended, PLT-R424).

## 11. Settings and storage

- Files in `~/Library/Application Support/<folder>/` (folder = display name if ASCII, else slug), directory
  0700, files 0600: `settings.json`, `app-modes.json`, `rule-overrides.json`, `macros.json`
  ([0307](docs/decisions/0307-settings-file-layout.md)). After a product rename, the first launch moves the
  previous folders (names listed in `AppLegacyStorageFolderNames`) to the new name before loading.
- Only explicit choices are stored; an absent key is "unset" and follows future defaults, a present key is a
  choice kept forever even if it equals today's default (PRD-R6, PLT-R1004). `DefaultSettings.v1` holds
  D1-D21.
- `SettingsStore` is an actor on the utility queue: atomic writes (temp file, `fsync`, `rename`) debounced
  1 s (5 s for app modes), unknown keys preserved, migrations as pure functions with backups, corrupt files
  quarantined and recovered from the newest backup, newer-schema files used read-only, crash-loop safe mode
  (PLT-R1002-R1009). After every change it publishes `SettingsState`; InputHost rebuilds the engine catalog
  and the tap snapshot, so changes apply on the next key without restart (PLT-R1008, PRD-R27).
- Export/import is one brand-neutral JSON file; macro import accepts the app's export, TAB-separated text,
  CSV and the Text Replacements plist, with a preview and a "keep mine / use imported" choice (PRD-R32,
  PLT-R1010, PLT-R912).

## 12. Diagnostics and privacy boundaries

| Data class (PLT-R901) | Examples | May be written to | Never |
|---|---|---|---|
| Content | keystrokes, composed text, field values, window titles, URLs, macro bodies, clipboard data | memory of the tap/engine/worker; `macros.json` and user lists (user-authored); time-boxed capture only | logs, reports, unified log, health events |
| Metadata | bundle keys, app versions, AX roles, rule IDs, timings, counters, layout IDs | logs (typed), reports, health events, histograms | free-form strings |
| Settings | the four documents | Application Support, export | reports (only non-content settings, macro count) |

- The logging API is typed (`LogEvent` cases carry enumerated metadata, `StaticString` or `Redacted`); a lint
  forbids string interpolation in log calls; `os_log` keeps default private redaction (PLT-R902). There is no
  verbose mode (PLT-R904).
- The tap never logs directly: it writes fixed-size `TapLogRecord`s into a lock-free ring drained by the
  utility queue into JSON-lines files (`~/Library/Logs/<folder>/`, 5 x 1 MB, 14 days, PLT-R903) and health
  events.
- Histograms (log2 buckets of atomics) cover T1, T2/T3, echo, T5, T6 and per-bundle AX durations (PLT-R801);
  signposts wrap callbacks, jobs and AX calls (PLT-R802).
- The environment report is structurally content-free: its type has no field that could hold content
  (PLT-R1203). The reported app's user override (PLT-R541) is a typed projection without `summary`, page URL
  prefixes or title patterns ([0312](docs/decisions/0312-report-override-projection.md)). It renders as reviewed
  plain text, as JSON, and as the machine-parseable issue block with a `<slug>-diagnostics v1` header line (ADR 0501)
  (QA-R44).
- The typing trace (PLT-R905) is the only artefact with characters: explicit start, 60 s default and 180 s
  maximum, menu icon and floating HUD with countdown, gaps during secure input, 0600 files excluded from
  backups, deleted after 24 hours or right after export.
- Network egress is Sparkle only (PLT-R906); no IPC listeners; the URL scheme can only open Settings
  (PLT-R909).

## 13. Permissions

Accessibility is required (`AXIsProcessTrusted`, `CGPreflightPostEventAccess`); Input Monitoring is
requested only if `CGPreflightListenEventAccess()` is false and the tap cannot be created or receives no
keys (PLT-R701, PLT-R702). `PermissionMonitor` polls every 2 s while not ready, every 30 s while ready, and
immediately on wake, session activation and menu open; it detects `stale` grants by comparing the designated
requirement digest with the last granted one (PLT-R720, PLT-R721). Onboarding checks the app's location
first (move offer, PLT-R710), then opens the pane through a deep link from `SystemPanes.json` and polls every
second. "Reset permission" runs `tccutil reset Accessibility <own bundle ID>` only after the user confirms
(PLT-R740).

## 14. Updates

Sparkle 2.10.1 pinned ([0304](docs/decisions/0304-sparkle-version-pin.md)): EdDSA-signed appcast on the site
host, beta channel only after opt-in, daily checks, background download, install on quit, no automatic
relaunch unless idle for 60 s with secure input off, no system profiling (PLT-R1101-R1106, PRD-R50-R55). The
EdDSA private key stays on Pa's Mac; publication runs from `scripts/publish-release` (release scripts track).
Each release links one bilingual release-notes page (Vietnamese first), because Sparkle chooses localized notes
by the macOS language, not the app's interface language (PRD-R51).

## 15. Shell

AppKit status item and menu rebuilt on open from `MenuModel`; non-activating `NSPanel` HUDs; SwiftUI
windows for Settings (five panes), onboarding (eight screens), macros, Apps pane, bug report, diagnostics,
latency probe and trace review ([0305](docs/decisions/0305-ui-framework.md)). The interface language switches
at runtime through per-language `.lproj` lookup, independent of the macOS language
([0310](docs/decisions/0310-localisation-runtime-switch.md)). Launch at login uses `SMAppService.mainApp`.

## 16. Testing architecture

| QA-R1 layer | Where | Needs permissions |
|---|---|---|
| 1-3 Engine unit, corpus, property/fuzz | `Packages/VietnameseEngine` (engine track) | No |
| 4 App logic | `swift test` in `Packages/AppCore`: settings, rules, matcher, hotkeys, importers, redaction, report, pipeline property suites with fakes | No |
| 5 Platform integration | `TestHost` app + XCTest/`compat-harness` against the real pipeline (QA-R10, QA-R11) | Yes: self-hosted runner only |
| 6 Compatibility | `compat/scenarios/*.json` via `compat-harness`, manual rows in `compat/matrix.json` | Yes |
| 7 Upgrade | Sparkle local appcast on the self-hosted runner or a VM (13.5) | Yes |

Layers 5-7 never run automatically on the maintainer's everyday Mac: posting synthetic events, creating taps and
changing input sources there is forbidden. Those items are listed for Pa in the traceability matrix. Until the
self-hosted runner exists, layers 5-7 are covered by an interim plan (workstreams.md "Interim verification"):
`compat-harness --dry-run` on hosted CI plus a short manual checklist Pa runs on Pa's own Mac.

## 17. Where to change what

| To change | Edit |
|---|---|
| How an app behaves | `compat/rules.json` plus a scenario in `compat/scenarios/` and a matrix row |
| A default | `SettingsStore/UserSettings.swift` `DefaultSettings` (after 1.0: ADR + release note, PRD-R5) |
| Copy | the owning String Catalog in `App/Resources/Localization/` (`Localizable` holds common strings) |
| System Settings pane names or deep links | `App/Resources/SystemPanes.json` |
| The product name | `scripts/rename-app.sh` (updates `Config/Brand.xcconfig` and `scripts/brand.env`) |
| The update feed or key | `Config/Sparkle.xcconfig` |
| A dependency or target | integrator change to `project.yml` or `Packages/AppCore/Package.swift` with an ADR |
