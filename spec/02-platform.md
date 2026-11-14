# 02 Platform: process model, input path, injection, compatibility, permissions, privacy, updates, diagnostics

| Field | Value |
|---|---|
| Document | 02-platform |
| Requirement prefix | PLT-R (numbered by section: PLT-R1xx = section 1, PLT-R2xx = section 2, ...) |
| Placeholders | `{{AppName}}` = display name, `{{app-slug}}` = ASCII slug. Bundle ID `vn.kal.{{app-slug}}`, Homebrew cask `{{app-slug}}`, site `{{app-slug}}.kal.vn` |
| Related | `01-engine.md` (ENG-R): syllable model, Telex/VNI rules, English restore, history, macros. `03-product.md` (PRD-R): menus, defaults, onboarding copy. `04-quality-release.md` (QA-R): tests, CI, release. This file is normative for everything between a physical key press and text appearing in another app. |
| Status | Draft for implementation, 2026-11-13 (adversarial review applied) |

## 0. Conventions and decisions

### 0.1 Conventions

- MUST, MUST NOT, SHOULD, SHOULD NOT, MAY follow RFC 2119.
- `VERIFY:` marks a claim that has not been confirmed on real hardware and the current OS. The implementer MUST confirm it before relying on it, then record the result (date, macOS build, app version) in the compatibility matrix or in a change to this file.
- `Rationale:` lines explain why. Many cite symptoms reported by users of a predecessor product ("prior art"); they describe behaviour only.
- Clean-room rule: this document was written from public documentation, user-reported symptoms and first-principles design. Implementers MUST NOT consult the source code of XKey, OpenKey, Unikey or any GPL input method while implementing it.
- Durations: µs = microseconds, ms = milliseconds. "Physical event" = an event that did not originate from {{AppName}}. "Synthetic event" = an event {{AppName}} posted.

### 0.2 Decision summary

| Topic | Decision | Section |
|---|---|---|
| Process model | One menu-bar process (LSUIElement). No helper daemons, no extensions, no IMKit bundle in v1 | 2 |
| Event tap | Session-level, head-insert, active filter, on a dedicated thread with its own run loop | 3.1 |
| Hot path | Tap callback only decides and enqueues. A serial injection worker posts edits | 3.2 |
| Ordering | Physical keyboard events are held and replayed behind in-flight edits. Event conservation invariant | 3.4 |
| Default injection | Synthetic backspace plus Unicode insertion, one grapheme per event, no pacing | 4.2 |
| App differences | Typed, data-driven rules (JSON) with provenance and one test per rule. No per-app code branches | 5 |
| Minimum macOS | 15.0 Sequoia (open question: 14) | 1 |
| Permissions | Accessibility (macOS 27 label: "Device Control and Data Access") required. Input Monitoring only if the OS demands it | 7 |
| Privacy | No keystroke content in logs. Time-boxed capture with on-screen indicator. Network egress = update checks only | 9 |
| Updates | Sparkle 2, EdDSA, appcast on `{{app-slug}}.kal.vn`, signing keys off CI by default | 11 |

## 1. Stack, packaging, minimum OS

- **PLT-R101** The code base MUST use Swift 6 language mode with complete strict concurrency checking, built with the latest stable Xcode at project start. VERIFY: GitHub runner images in November 2026 ship Swift 6.4.x and Xcode 27 as preview; pin the exact toolchain in CI at kickoff.
  Rationale: the hot path spans three threads; compiler-checked Sendable boundaries prevent the data races that unchecked shared singletons cause.
- **PLT-R102** The repository MUST be organised as SwiftPM packages with these targets (names are suggestions, responsibilities are normative):

| Target | Responsibility | May depend on |
|---|---|---|
| `VietnameseEngine`, `VietnameseEngineData` | Pure Vietnamese composition engine and its bundled word lists (`01-engine.md` section 12.1 owns the package layout and names). No I/O, no Apple UI frameworks | Swift standard library only (data target: Foundation for resource loading) |
| `InputHost` | Event tap thread, decision pipeline, layout tables, input-source state, focus tracking (AX thread), secure-input monitor, per-app memory | VietnameseEngine, CompatRules, Injection (protocol), Diagnostics (logging API), settings snapshot types |
| `Injection` | Serial injection worker, strategies, pasteboard preservation | Diagnostics |
| `CompatRules` | Rule schema types, loader, validator, matcher, engine fingerprinting, `compat-rules.json` resource | Foundation |
| `SettingsStore` | Versioned settings documents, migrations, export/import | Foundation |
| `Diagnostics` | Typed redacting logger, health events, histograms, reports, capture | Foundation |
| `Updater` | Thin wrapper around Sparkle 2 | Sparkle |
| `AppShell` | Menu-bar app, SwiftUI windows, onboarding, wiring | all of the above |
| `TestSupport` | Fakes: event poster, AX provider, pasteboard, clock; scenario runner | all non-UI targets |
| `CompatHarness` | Executable for CI: keyboard driver, scenario execution, readback | TestSupport |

- **PLT-R103** `VietnameseEngine` MUST be a separately versioned package licensed MPL-2.0 (ENG-R109) and MUST NOT import AppKit, CoreGraphics, Carbon or ApplicationServices, so that it can be tested on Linux CI and reused.
- **PLT-R104** The shipping binary MUST depend on Sparkle 2 only (no other third-party runtime code). Test-only dependencies are allowed. `Package.resolved` MUST be committed and Sparkle pinned to an exact version.
- **PLT-R105** The app MUST ship as a Universal binary (arm64 + x86_64). Rationale: macOS 12 to 26 run on Intel Macs, and Pa decided on 2026-11-13 to support Intel Macs for as long as the minimum macOS allows. CI runs the AppCore tests for the x86_64 slice under Rosetta on the Apple-silicon runner (docs/decisions/0315-minimum-macos-12.md).
- **PLT-R106** Minimum deployment target: **macOS 12.0 Monterey** (Pa's decision of 2026-11-13: support macOS as old as possible, and Intel Macs; docs/decisions/0315-minimum-macos-12.md). Rationale:
  - 12.0 is the oldest system the toolchain and the only dependency allow: Sparkle 2.10.1 declares `LSMinimumSystemVersion` 12.0 and the Xcode 27 macOS SDK has `MinimumDeploymentTarget` 12.0.
  - It keeps Macs that stop at Monterey, Ventura or Sonoma (for example MacBook Air 2018 and 2019, MacBook Pro 2016 and 2017) instead of excluding them.
  - Cost: the Swift `Synchronization` module (macOS 15), `Duration` and `Clock` (macOS 13), `@Observable` (macOS 14) and `SMAppService` (macOS 13) are not available. RealtimeSupport provides the replacements without third-party code (PLT-R104): `Atomic` and `UnsafeAtomic` on C11 atomic builtins with explicit memory orderings, `Mutex` on `os_unfair_lock`, and `TimeSpan` (signed nanoseconds) instead of `Duration`; models are `ObservableObject`; on macOS 12 the user adds the app to Login Items by hand (PRD-R8). Hot-path rules PLT-R304 and PLT-R305 are unchanged: no allocation after initialisation, no blocking lock on the tap thread, lock-free atomics where the tap reads.
  - Any API newer than macOS 12.0 MUST be used only behind `if #available` with a macOS 12 fallback; the release build MUST import no symbol newer than 12.0 without a weak link (checked against the macOS 12.0 SDK, ADR 0315).
  - Apple no longer ships security updates for macOS 12 to 14 (VERIFY Apple's current support statement); the app still runs there and the website says which systems are tested (PLT-R107).
- **PLT-R107** The supported test matrix is the latest point release of macOS 12, 15, 26 and 27, plus the current beta of the next major release from June each year. macOS 12 is smoke-tested in a virtual machine on the self-hosted runner (launch, permission onboarding, typing in TestHost, update; ADR 0315), Intel in CI through the x86_64 slice under Rosetta (PLT-R105) and on a real Intel Mac before each release when one is available (VERIFY). macOS 13 and 14 are supported but not separately tested: they fall between the tested floor and macOS 15, and GitHub no longer hosts runners for them.
- **PLT-R108** Licence note: the engine packages are MPL-2.0 (file-level copyleft, embeddable by any app; ENG-R109) regardless of the app licence. The app is GPL-3.0-or-later (decision of the product owner, 13/11/2026; `docs/decisions/0006-app-licence-and-pro-edition.md`): `compat-rules.json`, the injection layer and the diagnostics flow may be reused by others only under the GPL, so an open-source GPL-compatible project can reuse them and a proprietary one cannot. The rules database has no separate licence notice; it is covered by the root `LICENSE`. Making it freely reusable later needs a new decision and its own licence file (the inbound MIT grant of QA-R61 allows it for contributed rules).

## 2. Process architecture

- **PLT-R201** {{AppName}} MUST run as exactly one long-lived process: a menu-bar app with `LSUIElement = YES`. It MUST NOT install launch daemons, launch agents other than its own login item, privileged helpers, system or driver extensions, kernel extensions, browser extensions or XPC services in v1. Sparkle's installer helper runs only while an update is being installed.
  Rationale: the prior art ran event taps in two processes with a cross-process ownership handoff and a 500 ms timeout; failure modes included both sides staying passive and nobody transforming keys.
- **PLT-R202** Logical components inside the process:

| Component | Responsibility |
|---|---|
| Engine | Turns characters into composition edits (ENG spec) |
| Input host | Owns the event tap, the decision pipeline, layout translation, input-source awareness, focus context, per-app memory, secure-input state |
| Injection layer | Executes edit jobs in order using the strategy chosen for the focused field |
| Compatibility rules | Resolves the focused context to a strategy plus parameters |
| Settings store | Persists user choices, publishes immutable snapshots |
| Updater | Sparkle 2 integration |
| Diagnostics | Health state, redacted logs, histograms, reports, time-boxed capture, "this app misbehaves" flow |

- **PLT-R203** Thread map (normative):

| Thread | QoS | Run loop | Allowed work | Forbidden work |
|---|---|---|---|---|
| main | user-interactive | AppKit | UI, NSWorkspace notifications, TIS notifications, Sparkle UI, onboarding | Any per-keystroke work |
| `tap` | user-interactive, dedicated `Thread` | own CFRunLoop with only the tap source | Section 3.2 list | Section 3.2 list |
| `inject` | user-interactive, dedicated `Thread` | none (condition-variable driven loop) | Posting synthetic events, pacing waits, bounded AX reads/writes for injection, pasteboard snapshot/restore | Blocking on main or tap thread, unbounded waits |
| `ax` | user-initiated, dedicated `Thread` | own CFRunLoop with AXObserver sources | All focus-tracking AX calls, rule matching, engine fingerprinting | Posting events, file I/O beyond cached reads |
| utility queue | utility | GCD | Log draining and writing, settings persistence, secure-input polling, watchdogs, report generation | Hot-path work |

- **PLT-R204** If the process exits or crashes, macOS removes its event tap and keys flow normally. {{AppName}} MUST NOT install anything that outlives the process and intercepts input.
- **PLT-R205** Launch at login MUST use `SMAppService.mainApp`. `03-product.md` (D17) owns the default and the toggle.
- **PLT-R206** **v1 ships no IMKit input-method bundle.** Rationale:
  1. A zero-permission IMKit build can only compose with marked text, the same underlined composition that already breaks in Chromium, Word and Excel with the built-in macOS Vietnamese input source. For users who refuse permissions, the built-in source (Telex and VNI are available) is an equivalent fallback that costs nothing to maintain.
  2. A second process doubles lifecycle states. IMKit activation callbacks (`activateServer` / `deactivateServer`) are not guaranteed to arrive in order when focus moves quickly between clients (VERIFY on current macOS), so a second process would need its own reconciliation logic on top of the tap's.
  3. About 16 prior-art bug reports were specific to the IMKit component (underline covering one character, broken backspace after a word, Spotlight ESC broken, words lost on arrow keys).
  When permissions are missing, {{AppName}} MUST explain this honestly and point to the built-in Vietnamese input source.
- **PLT-R207** If an IMKit bundle is added later (candidate: a zero-permission or sandboxed edition), it MUST: never create an event tap or post CGEvents; use the same `VietnameseEngine` package; treat the currently selected TIS input source as the authority for activation (lifecycle callbacks are hints); communicate with the menu-bar app, if at all, only through XPC with code-signing requirements checked on both ends. While its input source is selected, the menu-bar app's tap MUST pass every key through.
- **PLT-R208** Single-transformer invariant: at any instant at most one component of {{AppName}} transforms a given key event.

### 2.1 Input host state machine

States: `noPermission`, `starting`, `ready(mode: vi|en)`, `paused(reason)`, `failOpen(reason)`.
Pause reasons: `secureInput(holder)`, `nonLatinInputSource(name)`, `builtInVietnameseSource`, `passThroughRule(ruleId)`, `secureField`, `sessionInactive`, `userDisabled`, `noTextFocus`.
Fail-open reasons: `permissionRevoked`, `postingBroken`, `tapUnavailable`, `watchdog`.

- **PLT-R210** Every transition into or out of `paused` or `failOpen`, and every focus change, MUST reset the composition (hard boundary, section 3.7).
- **PLT-R211** The menu-bar icon and menu MUST reflect the state truthfully, including the pause reason in plain words (for example "Paused: Secure Input is on, likely held by 1Password").

### Acceptance criteria (section 2)

- Activity Monitor shows one {{AppName}} process; `launchctl list` shows no {{AppName}} daemons; no extensions are registered.
- Killing the process with `kill -9` while typing leaves the keyboard fully functional within the same keystroke.
- The bundle contains no `.app` under `Library/Input Methods` and no IMKit `Info.plist` keys.

## 3. Primary input path

### 3.1 Tap placement

- **PLT-R301** {{AppName}} MUST create exactly one active event tap with location `kCGSessionEventTap`, placement `kCGHeadInsertEventTap`, option `kCGEventTapOptionDefault`, and an event mask of `keyDown`, `keyUp`, `flagsChanged`, `leftMouseDown`, `rightMouseDown`, `otherMouseDown`. The system additionally delivers `tapDisabledByTimeout` and `tapDisabledByUserInput`.
  Rationale, session level rather than HID level:
  - Session taps see events from the HID system and from remote-control sources (Screen Sharing, the Accessibility Keyboard), so Vietnamese works with on-screen and remote input into this Mac.
  - Remappers that work below the window server (hidutil, Karabiner-Elements' virtual keyboard) already applied their remaps, so the engine sees the characters the user effectively typed.
  - Synthetic events posted at the session location pass back through the same tap, which gives a free delivery confirmation (echo, PLT-R323).
  Rationale, head insertion: {{AppName}} transforms before other session-level consumers, so text expanders and automation tools observe the final Vietnamese text.
  VERIFY: (a) events posted with `CGEventPost(kCGSessionEventTap)` from the `inject` thread are delivered to {{AppName}}'s own session tap; (b) coexistence with Karabiner-Elements, BetterTouchTool, Keyboard Maestro, Raycast hotkeys, TextExpander and Espanso.
  `scrollWheel` MAY be added to the mask only because the modifier-only toggle recogniser in `03-product.md` (PRD-R14) cancels on scroll; for scroll events the callback MUST do nothing except set a "chord cancelled" flag and return the event unchanged.
- **PLT-R302** No second tap and no listen-only shadow tap may exist.
- **PLT-R303** The tap MUST run on the dedicated `tap` thread whose CFRunLoop contains only the tap's run-loop source. The thread does nothing else.
  Rationale: the prior art ran its tap on the main run loop together with synchronous Accessibility calls and sleeps; users reported per-keystroke lag and machine-wide freezes of several seconds.

### 3.2 Hot-path rules

- **PLT-R304** Inside the tap callback only these operations are allowed: reading event fields; one atomic load of each published snapshot (settings, focus context, input-source state); table lookups in precomputed layout tables; one synchronous call into the engine; pushing onto a lock-free single-producer queue; atomic counter updates; lock-free histogram increments; writing fixed-size records into a lock-free log ring buffer.
- **PLT-R305** Inside the tap callback these are forbidden: any Accessibility API call, file or network I/O, blocking logging, `sleep`/`usleep`/`nanosleep`, semaphore or condition waits, locks that another thread can hold for unbounded time, `DispatchQueue.sync`, Swift `async`/`await`, messaging AppKit objects, TIS calls, NSWorkspace calls, pasteboard access. Steady-state heap allocation SHOULD be avoided (preallocated buffers).
- **PLT-R306** A watchdog on the utility queue MUST observe a per-callback "entered at" timestamp. If one callback has been executing for more than 250 ms, the watchdog MUST disable the tap (`CGEventTapEnable(false)`, which lets keys flow), record a `watchdog` health event, enter `failOpen(watchdog)`, then attempt recovery after 2 s.
- **PLT-R307** Contract with the engine (informative here, normative in `01-engine.md` section 12): the engine is synchronous and pure (`reduce(state, event)`); processing one event has a bounded cost (ENG-R1230: p50 5 µs, p99 25 µs, p99.9 100 µs); it never traps on any input sequence; it accepts the events `key(character, fromKeypad)`, `backspace`, `restoreToggle` and `reset(reason)` (boundary keys such as space and punctuation are ordinary `key` events, ENG 9.2); it returns either `passThrough` or `edit(deleteCount, deleteUTF16Count, insert, thenPassThrough)` where `deleteCount` counts grapheme clusters the engine itself emitted or passed through and `insert` is NFC text. It keeps for every keystroke the layout-resolved character actually typed, so that restore reproduces exactly what the user typed (for VNI that means digits, never Telex letters).

### 3.3 Decision pipeline

- **PLT-R310** For each event the callback MUST apply these steps in order:
  1. `tapDisabled*`: handle per section 3.6 and return.
  2. Event carries {{AppName}}'s marker (PLT-R321): record the echo and return the event unchanged.
  3. Mouse down: post a hard-boundary signal (section 3.7) and return the event unchanged. Mouse events are never held.
  4. Load snapshots: settings, focus context, input-source state.
  5. Hotkeys (VI/EN toggle and the restore hotkey, `03-product.md` PRD-R14 to PRD-R18). Modifier-only hotkeys fire on release only if no other key was pressed during the hold.
  6. If state is `paused`, `failOpen`, mode is EN, or the resolved strategy is `passThrough`: do not feed the engine; go to step 10 with outcome "pass".
  7. Translate keycode plus modifier state to a character with the layout table (section 3.9) and classify: character, user backspace, navigation, Escape, Return/Tab, command/control chord, dead key, function key.
  8. Feed the engine. Obtain pass, edit, restore or boundary.
  9. Map to an outcome: pass; edit job; restore job; boundary.
  10. If the outcome needs injection, or the injection queue is busy (PLT-R311), return NULL (swallow) and push the job or a replay job; otherwise return the event unchanged.

### 3.4 Ordering, holding, conservation

- **PLT-R311** The `inject` worker executes jobs strictly FIFO. Job kinds: `EditJob`, `ReplayJob` (copy of a held physical event), `BoundaryJob`. While `inFlight > 0` (jobs pushed but final event not yet posted), every keyboard event (`keyDown`, `keyUp`, `flagsChanged`) that the pipeline would pass through MUST instead be swallowed and pushed as a `ReplayJob`. Rationale: a later physical key must never reach the app between the backspaces and the insertion of an earlier edit; users reported garbled words when typing fast in Zalo's search box.
  - **The keyUp of a passed keyDown** *(amendment, 2026-11-15, ADR 0322; the product owner's dev traces of 14 and 15/11/2026)*. A `keyUp` whose `keyDown` (or its last autorepeat) the pipeline passed unchanged is not held: it passes at once, even while `inFlight > 0`. A keyUp inserts no text, so it cannot land between the backspaces and the insertion of an edit. Holding it gave the app the keyboard's keyDown but a keyUp rebuilt by the worker (PLT-R324), and in a messenger built on WKWebView every key released within one or two milliseconds of a tone key was then lost at its next press: 5 of 5 such keys a readback could check, against 0 of 89 rollovers whose keyUp had passed. A keyDown that was held (queued as a `ReplayJob`, autorepeat included) keeps its keyUp behind its own replay, and `flagsChanged` events stay held (a modifier release that overtook a held key typed with that modifier would change that key's meaning for apps that track modifier state). The 13.1 property tests check that such a keyUp is never replayed and still reaches the app after its own keyDown.
- **PLT-R312** Event conservation invariant: every physical keyboard event has exactly one outcome: passed unchanged, replayed once after all earlier jobs, consumed as an engine trigger whose effect is delivered by an `EditJob`, or consumed as a hotkey. No event is dropped silently or delivered twice. Enforced by property tests (section 13.1).
- **PLT-R313** If a `keyDown` is consumed for an edit, its matching `keyUp` (same keycode) MUST also be consumed. Synthetic edits post their own down/up pairs. Rationale: games, JVM apps and remote clients track key state.
- **PLT-R314** Liveness ceiling: if the oldest held event has waited longer than 150 ms (default; VERIFY tuning), or the queue exceeds 256 jobs, the worker MUST abandon edit jobs that have not started, replay all held events in order, reset the composition, and record a `flush` health event. Rationale: a garbled word is acceptable, a stalled keyboard is not.
- **PLT-R315** The worker MUST NOT wait on the main thread or on the tap thread. It waits only on its own queue condition, its pacing deadlines, and bounded AX or pasteboard calls.
- **PLT-R316** Focus generation: every job records the focus-context generation current when it was created. The worker MUST discard an `EditJob` whose generation is older than the current one (focus moved) and replay any held events behind it. Rationale: an edit computed for one field must never be applied to another.
- **PLT-R317** A mouse click that arrives while a paced job is in progress is not held (holding a down without its drag events would reorder input). The in-flight job completes; the hard boundary applies to the next key. Known residual risk: a click within a few milliseconds of a paced edit may move the caret mid-edit. Acceptance: rare and bounded to one word.

### 3.5 Self-generated events

- **PLT-R320** Synthetic events MUST be created from a `CGEventSource` with state ID `privateState`, carry explicitly set flags (no inherited modifier state), and use a local-events suppression interval of 0 so posting never suppresses the user's hardware input. VERIFY the default suppression behaviour on macOS 15, 26 and 27.
- **PLT-R321** Every synthetic event MUST set `kCGEventSourceUserData` to a value composed of a per-launch random tag (at least 40 bits from a CSPRNG) and a sequence number. Physical events MUST NOT be modified in place, including no marker on events that are passed through. Rationale: a marker on physical events would be visible to every other session-level consumer (text expanders, remappers, automation tools) and would make the echo check of PLT-R323 ambiguous.
- **PLT-R322** Synthetic events MUST be posted at `kCGSessionEventTap`.
- **PLT-R323** Echo liveness: the worker records the sequence number of the last event of each job; the tap marks it seen when it passes. If three consecutive jobs see no echo within 200 ms, the platform MUST assume posting is broken (permission revoked or OS policy) and enter `failOpen(postingBroken)` (section 7.4). Depends on PLT-R301 VERIFY (a); if echoes are not delivered, fall back to permission polling only and remove this requirement.
- **PLT-R324** Replayed events MUST be copies of the original with keycode, flags, autorepeat field, keyboard type and Unicode string preserved, plus {{AppName}}'s marker.

### 3.6 Tap disabled by the system

- **PLT-R330** On `tapDisabledByTimeout` or `tapDisabledByUserInput` the input host MUST: (1) re-enable the tap immediately if permissions are still valid; (2) reset the composition and clear engine re-entry history; (3) replay held events in order; (4) record a health event with the reason; (5) after more than 3 such events within 10 minutes, show a non-modal diagnostics notice. Rationale: the prior art re-enabled without resetting engine state, so the next edit used stale buffers and deleted the wrong characters.
- **PLT-R331** A watchdog (every 5 s with leeway, and on wake, session activation and permission change) MUST call `CGEventTapIsEnabled`; an unexpectedly disabled tap triggers the same procedure.
- **PLT-R332** If tap creation returns nil, the host enters `failOpen(tapUnavailable)` and retries with backoff 1, 2, 5, 10 s (cap) only while permissions appear granted.
- **PLT-R333** Fast User Switching and sleep: on session resign-active, sleep or screen lock, the host MUST reset and enter `paused(sessionInactive)`; on become-active or wake, it MUST validate the tap and permissions before returning to `ready`.

### 3.7 Composition boundaries

- **PLT-R340** Hard boundary (composition and re-entry history cleared) MUST be signalled on: focus change (application or element), mouse down, navigation keys (arrows, Home, End, Page Up, Page Down, Forward Delete with or without modifiers, and Option+Backspace, which deletes a word), any keyDown with Command or Control (including Command+Backspace, which deletes to the start of the line, and Control+Backspace), Return/Enter, Tab, Escape when it is passed through (an Escape consumed as the restore hotkey is not a boundary, so the engine can keep the token, ENG-R701/702), input-source change, VI/EN toggle, secure-input transitions, tap disable or re-enable, flush, sleep or wake, screen lock, session switch, permission change, a change of resolved rule or strategy for the focused field, and settings changes that affect the engine.
  - **Late focus change** *(amendment, decision of the product owner, 14/11/2026, T5.5: Command+S, then `dduowngf` typed at once in TextEdit's save sheet gave "ddường"; integration-suite.md section 10.5)*. When the tap discovers a focus change only after keys of the active token were composed with the previous snapshot, it keeps the composition (no boundary, no reset) if all of these hold: the new focused element belongs to the same process, or the previous snapshot named no process because its system-wide focus read timed out (amendment of 2026-11-15: in the product owner's Safari trace a timed-out read published a snapshot without an app, and the next real snapshot of Safari reset the word as an application change); it has an AX element and AX is available; the snapshot has no focus pause; the engine variant is unchanged; and the change was observed (`changedAt`) at most 500 ms after the token's last key. 500 ms covers a change the typing caused (a sheet or an editor taking the key it was opened by) or that the app reported late within the settle window (last re-read 400 ms after the notification, PLT-R380), and equals the PLT-R382 typing-pause threshold, beyond which a key is no longer part of continuous typing. The first job after the discovery verifies with a bounded AX read (PLT-R343) that the new element is readable and that its text before the caret (before the selection when an inline completion is selected) ends with the token's display, preceded by the start of the text or a separator (whitespace, punctuation, symbol), read in the same bounded read so text that merely ends with the token ("Nova" for `a`) does not count; that job carries the check even when the key needs no edit (the key is then held behind it, PLT-R311). If the element is unreadable or the text does not match, the key passes through unchanged and the composition is reset: the hard boundary, applied one key late. Until the check ran, the restore hotkey passes through (an Escape may close the sheet). Every other focus change stays a hard boundary.
- **PLT-R341** Space, punctuation and other word separators are soft boundaries: they commit the word but MUST NOT clear re-entry history. Backspacing over them returns to the previous word's composition (the ENG spec defines how many words). Rationale: prior-art users could not fix a tone after backspacing over ", ", ". " or a double space.
- **PLT-R342** Re-entry verification: when backspacing into a previous word would make the engine edit that word, and the rule's `verifyReentry` is not `never`, the worker SHOULD read at most 64 characters before the caret via a bounded AX call (`kAXStringForRangeParameterizedAttribute`) and compare with the expected word. On mismatch (autocorrect, dictation, paste via menu changed it), the engine history is dropped and keys pass through.
- **PLT-R343** AX reads on any thread MUST be bounded: never read the full `AXValue` of a field; use the selected range plus a parameterized range read of at most 64 characters. Rationale: prior-art users reported lag in Apple Notes documents over 5,000 words, even with Vietnamese off.

### 3.8 Keys

- **PLT-R350** Shift and Caps Lock determine case through the layout table. The host also passes the Caps Lock state with every key to the engine (`KeyInput.capsLock`), because keys without case (Telex bracket keys) take their case from it (`01-engine.md` ENG-R906). Command or Control chords pass through and are hard boundaries. Option chords that produce a character pass through and are hard boundaries unless the ENG spec assigns them a meaning.
- **PLT-R351** Autorepeat (`kCGKeyboardEventAutorepeat = 1`): character keys pass through untransformed and end the composition; backspace repeats pass through and are reported to the engine one by one so its state stays coherent; navigation repeats pass through.
- **PLT-R352** User backspace passes through (or is held while busy) and is reported to the engine. The engine may answer with an edit (re-composition); otherwise it passes. Only a plain or Shift Backspace is reported. Option+Backspace (deletes a word in Cocoa text) is a navigation key; Command+Backspace (deletes to the start of the line) and Control+Backspace are Command or Control chords; Forward Delete, with or without modifiers, is a navigation key. Each is a hard boundary (PLT-R340) and resets the engine (`01-engine.md` ENG-R1010), because the app deletes text the engine cannot count. A Backspace-triggered edit MUST NOT delete more than the active token's display (`01-engine.md` ENG-R714); if the engine ever answers with a larger deletion, the host does not apply it: the Backspace passes through and the engine is reset. Rationale: the product owner saw one Backspace take a whole word in chat apps (14/11/2026).
- **PLT-R353** Restore hotkey: Escape by default, with an on/off setting (`03-product.md` D8, PRD-R18; decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md). When the bound key (Escape unless the user chose another) is pressed and the engine answers `restoreToggle` with an edit (ENG-R701), the key is consumed and the edit typed back exactly as recorded. When the engine answers `passThrough` (nothing to restore, or a second consecutive press, ENG-R702), the key passes through untouched and, for Escape, is a hard boundary. Rules disable the binding per app (`features.restoreHotkey: false`) in terminals, IDEs and code editors, games and remote desktop clients, and in launchers such as Spotlight, Raycast and Alfred, where Escape has its own meaning; these exclusions live in `compat/rules.json`, never in per-app code (PLT-R501). Rationale: Escape closes Spotlight, dialogs and popovers; the prior art's IMKit path broke closing Spotlight with Escape.
- **PLT-R354** Dead keys: if the layout translation yields a dead-key state, the dead key and the following key pass through untouched and a hard boundary is signalled.
- **PLT-R355** Keypad digits MUST NOT act as VNI tone keys by default. Rationale: number entry in spreadsheets.
- **PLT-R356** Navigation keys, including Up and Down in search fields and completion lists, MUST never cause an edit. Rationale: the prior art's IMKit path deleted the word being typed when the user pressed Up or Down to pick a suggestion.

### 3.9 Layout independence

- **PLT-R360** The engine consumes characters, not keycodes. The input host MUST translate keycode plus modifier state to a character with the current keyboard layout's `uchr` data (`UCKeyTranslate`), precomputed off the hot path into a table per layout ID for the states none, Shift, Caps Lock, Shift+Caps Lock, and rebuilt on input-source change.
- **PLT-R361** Telex letters and VNI digits are the characters the user's layout produces: QWERTZ `y`/`z`, AZERTY `a`/`q`/`w`, Dvorak positions, VNI digits on AZERTY (which require Shift) all work. Rationale: prior-art users on a German QWERTZ layout reported that typing `y` removed tone marks and `z` did not, because some keys were interpreted by position.
- **PLT-R362** Diagnostics MUST include the layout identifier (for example `com.apple.keylayout.ABC`).
- **PLT-R363** Debug builds SHOULD cross-check the table against `CGEventKeyboardGetUnicodeString` of physical events and log mismatches as keycode plus layout ID only. VERIFY whether physical events at session level always carry a populated Unicode string; if reliable, it MAY become the primary source.

### 3.10 Input-source awareness

- **PLT-R370** The host MUST observe `kTISNotifySelectedKeyboardInputSourceChanged` (distributed notification, delivered immediately), compute the new input-source state on the main thread, and publish a snapshot.
- **PLT-R371** The host MUST pass every key through (`paused(nonLatinInputSource)`) when the selected source is an input method or input mode (Japanese, Chinese, Korean, third-party IMEs) or a keyboard layout that is not ASCII-capable. Transformation happens only under ASCII-capable keyboard layouts.
- **PLT-R372** If a macOS built-in Vietnamese input source is selected, the host MUST pause with `builtInVietnameseSource` and explain that two transformers would conflict.
- **PLT-R373** Optional binding (off by default): the user designates ASCII-capable layouts as VI or EN (for example "ABC" = VI, "U.S." = EN). When enabled, the selected source decides the mode, so the Globe key or Control+Space toggles Vietnamese. When disabled, the VI/EN mode is independent of the input source. Precedence: while a designated layout is selected, it decides the mode ahead of the toggle hotkey, per-app memory and rules, and the global mode, and the toggle hotkey does nothing (switching layouts is the toggle); on a layout that is not designated everything works as without the binding, and an app set to `Bỏ qua` stays ignored. *(Rule from the final review, recorded under the product owner's delegation on 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md.)*

### 3.11 Focus context and text-context gating

- **PLT-R380** The `ax` thread owns all focus-tracking AX calls. It keeps AXObservers on (a) the focused application and (b) applications flagged `overlay: true` in rules (for example Spotlight, Raycast, Alfred), for focused-element changes, focused-window changes, application activation, and title changes only when a rule for that bundle uses `titlePattern`.
- **PLT-R381** Focus authority: the system-wide AX focused application and focused element are authoritative. NSWorkspace activation notifications only trigger revalidation. Rationale: non-activating panels such as Spotlight, Raycast and Alfred take keyboard focus without becoming the frontmost app; prior-art users reported Raycast ignoring the remembered mode.
  - **Frontmost-app fallback** *(amendment, 2026-11-15: in the product owner's dev trace of 15/11/2026, 685 key downs went to an app whose focused application the Accessibility API did not name, most likely an Electron code editor; without a bundle ID no per-app rule, mode or setting applied there)*. When the system-wide AX read succeeds but names no focused application, the focus snapshot takes NSWorkspace's frontmost application as the focus owner, marked as a weaker identity (`frontmostApplication`). Bundle- and engine-level rules, the app's VI/EN mode and memory (PLT-R390), its per-app rule (`03-product.md` PRD-R21) and its per-app word lists apply. No AX call goes to that application's focused element, so the snapshot has no element, role, subrole, identifier, DOM class, ancestor, title or URL, and no rule that needs one of them matches (5.2). A timed-out or failed system-wide read never falls back, because the focus is then unknown rather than empty (PLT-R340, PLT-R384), and the AX focus wins as soon as it names an application. The frontmost application is read on the `ax` thread where the focus snapshot is built (its identity once per process, like the AX owner's), never in the tap callback (PLT-R304, PLT-R305). The Diagnostics report and the dev recorder say that the app was taken from the frontmost application (PLT-R1202, PLT-R904A). For the late focus change of PLT-R340 such a snapshot names its process: a field of the same process seen right after it may keep the word; another process is an application change.
- **PLT-R382** Idle revalidation: when the tap sees a keyDown after at least 500 ms without keyboard input, it sets a lock-free flag that makes the `ax` thread revalidate system-wide focus. The key itself is processed with the current snapshot and never waits. The first keyDown after the tap starts counts as idle. Events that can move the focus without a notification: PLT-R389.
- **PLT-R383** The focus snapshot contains: pid, bundle ID, app version, engine fingerprint (section 5.3), AX availability (`available`, `unavailable`, `timedOut`), role, subrole, AX identifier, DOM class list when exposed, editable flag, secure flag, per-rule booleans for title and web-URL matches (the title and URL strings are not kept in the snapshot), the resolved rule decision (strategy, parameters, rule ID, source: shipped, user or default), whether the app came from the AX focus or the frontmost-app fallback (PLT-R381), and a generation counter.
- **PLT-R384** AX timeouts: `AXUIElementSetMessagingTimeout` MUST be set to 100 ms on every application element and on the system-wide element. Circuit breaker: 3 timeouts within 10 s for one pid stop AX queries to that pid for 60 s; the snapshot marks AX `timedOut` and decisions fall back to bundle- or engine-level rules. Rationale: JVM apps and hung apps answer AX slowly; prior-art users reported IntelliJ freezes.
- **PLT-R385** {{AppName}} MUST NOT set `AXEnhancedUserInterface` on any application. It MAY set `AXManualAccessibility` on an application only when a rule requests it (`axEnable: manual`) and MUST record that it did. Rationale: `AXEnhancedUserInterface` is known to disturb window animation and positioning and caused lag in Chromium; enabling accessibility in Electron apps can change their behaviour (VERIFY: VS Code may switch to screen-reader mode). VERIFY: a third-party report says Chrome 155 and later reject `AXManualAccessibility`.
- **PLT-R386** Text-context gating, parameter `requireTextFocus` with values `never`, `whenKnown`, `always`:
  - `whenKnown`: if AX reports a focused element that is definitely not editable text, pass through and reset.
  - `always`: transform only when AX confirms an editable text element.
  - Default: `whenKnown` for engines `native` and `catalyst` (AX is reliable there); `never` for all other engines unless a rule says otherwise.
  - Editable text means role `AXTextField`, `AXTextArea`, `AXComboBox`, subrole `AXSearchField`, or a web element that AX marks as editable (VERIFY the attribute names Chromium and WebKit expose), plus roles a rule adds.
  Rationale: prior-art users reported that double letters in Telex (aa, ee, dd) deleted the selected shape in Illustrator, Affinity and Photoshop, because the first letter was consumed as a tool shortcut and the second produced a synthetic backspace.
- **PLT-R387** Secure fields: if the focused element's subrole is `AXSecureTextField`, the host MUST pass through, reset and never capture, regardless of rules or user overrides.
- **PLT-R388** The snapshot is an immutable value published through one atomic reference. The tap reads it with a single atomic load.
- **PLT-R389** Revalidation after events that can move the focus without an app activation *(from the product owner's manual tests of 14/11/2026, items 7 and 9: Spotlight typed "teẽ" for `tex` and "vieêệt" for `vieejt`, and its second opening turned Escape into a restore, because the snapshot still named the previous app)*. A non-activating panel (Spotlight, Raycast, Alfred) opening or closing, a sheet or a popover taking the focus post no activation notification and may post no AX notification the `ax` thread observes. Therefore:
  - Triggers: any keyDown with Command or Control, Escape, Return, Tab (autorepeats excluded) and every mouse down. The tap pushes a lock-free notice; the `ax` thread does not read at once (the tap still holds the key, so the panel or sheet it opens cannot have the focus yet) and reads the system-wide focused application and element 25, 60, 100, 150, 220 and 400 ms after the trigger. These reads are idle reads: an unchanged focus publishes nothing, a timeout ends the window (PLT-R384), a later trigger restarts it. The read schedule is dense over the first 200 ms because such panels take the focus within tens of milliseconds to about 200 ms of the key, and the next key typically follows 80 to 300 ms later.
  - The first keyDown after a trigger asks for one more immediate read, like PLT-R382.
  - While the resolved rule of the focus owner has `overlay: true`, every keyDown asks for an immediate read, so the keys typed after the panel closed (Escape, a click outside, Return) use the previous app's rules.
  - The trigger reads, the read of the first keyDown after a trigger and the overlay reads are moved-only reads: when the focused application and element are the published ones, the element's attributes (role, ancestors, DOM classes, web area, URL, title) are not read and nothing is published. Command+C, Command+V and clicks are frequent, and every attribute walk is served by the focus owner's main thread and counts towards its breaker on a timeout (PLT-R384). A change of the same element's attributes is left to AX notifications and to the full PLT-R382 read after a pause; a keyDown that is both idle and after a trigger reads in full.
  - The tap never waits for these reads (PLT-R304, PLT-R305): a key composed on a stale snapshot is protected by the generation check (PLT-R316) and, within one process, by the late focus change rule of PLT-R340.
  Acceptance: unit tests with fake AX (`FocusTriggerSettleTests`, `FocusTriggerTests`); TestHost scenarios `testhost.sheet.commandS` and `testhost.panel.*`; manual T5.5 and T5.8 on macOS 27.

### 3.12 Per-app memory

- **PLT-R390** VI/EN mode memory is keyed by the focus owner's bundle ID (PLT-R381), so overlay panels have their own memory. Default on. An app seen for the first time uses the current global mode unless the resolved rule sets `defaultMode`. User per-app rules take precedence over memory in the order defined by `03-product.md` PRD-R21 (ignore > always English > always Vietnamese > remembered > default); "ignore" is implemented as a user override with strategy `passThrough`.
- **PLT-R391** A mode change caused by focus change MUST be in effect before the next key is processed (snapshot generation).
- **PLT-R392** Storage: LRU of at most 1,000 entries; writes debounced by 5 s; only bundle ID and mode are stored.
- **PLT-R393** Processes without a bundle ID are keyed by the SHA-256 of their executable path.

### 3.13 Secure Input

- **PLT-R395** Secure Event Input MUST be detected with `IsSecureEventInputEnabled()` polled every 2 s (with leeway) on the utility queue, and immediately when the menu opens.
- **PLT-R396** Holder identification: read the `IOConsoleUsers` property from the IORegistry root, take `kCGSSessionSecureInputPID`, and map it to an app name and bundle ID. Present it as the "likely holder" because the value is known to be unreliable: it can name whichever app was frontmost when a background process enabled secure input, it can point to `loginwindow` after a lid close without locking, and it can keep a PID whose process has exited. If the PID is dead or belongs to `loginwindow`, advise locking and unlocking the screen (Control+Command+Q) or logging out.
- **PLT-R397** While secure input is on: state `paused(secureInput(holder))`, composition reset on entry and exit, menu shows the holder and a short data-driven hint (for example "Terminal: turn off Secure Keyboard Entry in the Terminal menu"; "Browser: click outside the password field or switch tabs"). No modal alerts. Rationale: "Secure Input stuck" was a common prior-art report, including a browser keeping secure input while a password field stayed focused.
- **PLT-R397A** *(amendment, 2026-11-15)* Input hidden from the tap. Event taps receive no key events while secure input is on (PLT-R398D), and an episode shorter than the poll interval is never seen as a pause: in the product owner's trace of 14/11/2026 a background process turned secure input on and off in bursts of 55 to 300 ms, the tap missed a Space and a letter the app received, and a later edit deleted them by count ("hay sao" became "hayayao"). The tap MUST keep a fixed set of the key codes it saw go down (no allocation, PLT-R304). A `keyUp` of a non-modifier key that the tap never saw go down, and whose keyDown {{AppName}} did not consume, proves that the app received input the engine did not see: the tap takes a hard boundary (PLT-R340; boundary job `unseenInput`, engine reset reason `unknown` until the engine defines one) and logs the key code only. A key already down when the tap starts costs at most one such boundary. The protection is partial: an edit made between the hidden keyDown and its keyUp can still delete what the app received.
- **PLT-R397B** *(amendment, 2026-11-15)* Secure-input bursts. An episode that key evidence ended (PLT-R398B) less than 1 s after the poll saw it start happened while the user was typing; a password typed into a secure field lasts longer, and an episode a poll ends lasts about one poll interval. When 3 such episodes end within 10 minutes, the app records one content-free `secureInputBursts` health event (the count, no holder: PLT-R396 may name whichever app was frontmost), at most one per 10 minutes, so Diagnostics can tell the user that something keeps turning secure input on and off: for 24 hours after such an event the Diagnostics window shows a label and a plain explanation under its state line, and the report text and the copied block carry the same words (`03-product.md` 11.1). The dev recorder's secure gap lines carry the likely holder's bundle ID and process ID (PLT-R396) and the gap's duration (PLT-R904A).
- **PLT-R398** {{AppName}} MUST never call `EnableSecureEventInput`.
- **PLT-R398A (P0-1, product owner)** Pausing for security MUST rely only on two signals: the operating system's secure-input state (PLT-R395) and a focused field whose role is `AXSecureTextField` (PLT-R387). {{AppName}} MUST NOT guess "a password is being typed" from window titles, prompt text, terminal echo state or any other heuristic. Rationale: the product owner's top complaint is Vietnamese being blocked "at random" in iTerm2 because something decided a password was being typed.
- **PLT-R398B (P0-1)** Resume without delay: a regular key-down that reaches the tap proves that secure input is no longer blocking it. On the first such event while in `paused(secureInput)`, the app MUST leave the paused state and process that key normally (composition starts fresh). It MUST NOT wait for the next poll. Acceptance: in the automated scenario, the first key typed after secure input is released is composed, with no passed-through keys in between.
- **PLT-R398C (P0-1)** Terminal hints MUST cover the cases where a terminal raises secure input on its own: iTerm2 turns on secure keyboard entry automatically while it believes a password prompt is showing (its password-prompt detection), in addition to the manual "Secure Keyboard Entry" menu item; Terminal.app has the menu item only. The hint names the app and says, in one line, how to stop it: turn off the menu item; for iTerm2 also finish or cancel the password prompt it is waiting for. iTerm2's public documentation describes the menu item (iTerm2 > Secure Keyboard Entry) and its password-prompt detection (terminal echo turned off for a moment), and documents no on/off setting for the automatic behaviour (its release notes mention only a detection debounce, the advanced setting `DetectPasswordInputDebounce`, notes 3.7.0beta3), so the hint quotes no setting (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md). VERIFY: whether the detection fires on TUIs (CLI agents, editors) that turn off terminal echo. VERIFY: whether iTerm2 Settings > Advanced lists a switch for the automatic behaviour in the shipping build; if it does, the hint may name it after a support review.
- **PLT-R398D (P0-1, spike S1 before v0.1)** Measure whether an InputMethodKit input method still receives key events in iTerm2 and Terminal.app while secure keyboard entry is on (event taps do not: Apple TN2150). If it does, plan a v1.x "terminal mode" that uses an IMKit input source for apps holding secure input, under PLT-R207 (such a bundle never creates an event tap). Record the result in `docs/decisions/`.

### 3.14 Conflicting input software

- **PLT-R399** The host MUST detect other running Vietnamese input apps (bundle IDs listed in the rules resource) and enabled macOS Vietnamese input sources, and warn once per launch with a plain explanation. It MUST NOT terminate other apps.

### Acceptance criteria (section 3)

- Instrumented builds show zero AX calls, file writes, sleeps or lock waits on the `tap` thread across a 30-minute typing session (verified with signposts and a debug assertion layer).
- Property test: random interleavings of keys, mouse downs, focus changes, tap-disabled events, secure-input toggles and permission changes never violate PLT-R312 over 100,000 sequences.
- Telex "duyeetj" yields "duyệt" under ABC, German (QWERTZ), French (AZERTY) and Dvorak layouts; VNI "duye65t" yields "duyệt" under ABC and AZERTY.
- With a Japanese input source selected, no key is transformed and the menu shows the pause reason.
- Simulated tap timeout mid-word (test hook that delays the callback): the next word is composed correctly and no characters are deleted wrongly.
- Holding Z or Space in a design app produces no visible delay compared with {{AppName}} not running (latency probe delta under 1 ms).
- Escape closes Spotlight on the first press when no transformation is pending.

## 4. Injection strategy catalogue

### 4.1 Common job model

- **PLT-R401** An `EditJob` contains: strategy, parameters, `deleteCount`, `insertion`, triggering keycode, focus generation, sequence range.
- **PLT-R402** The injection layer MUST minimise every edit by trimming the common grapheme prefix of the text being deleted and the insertion (for example "nguyen" plus `s` deletes "en" and inserts "ến").
- **PLT-R403** Insertions MUST be NFC. Deletion counts are grapheme clusters the engine emitted.
- **PLT-R404** Unicode events carry one grapheme cluster per keyDown/keyUp pair by default (`unicodeChunk = 1`). A rule MAY raise this to at most 20 UTF-16 code units. Rationale: `CGEventKeyboardSetUnicodeString` processes at most about 20 code units (undocumented, widely reported), and many apps take only one character per event (Terminal is a known exception).
- **PLT-R405** Unicode events MUST use the keycode of the physical key that triggered the edit (for restores and macros: the keycode of the first character of the insertion, or else of the replaced text, that the current layout types on a key that is not one of the action keys below; otherwise the triggering key). A key whose keycode carries an action of its own never carries a Unicode string: Backspace, Return and keypad Enter, Tab, Space and Escape (Forward Delete never triggers an edit, PLT-R340, and is never posted, PLT-R407). An edit one of them triggers (a Backspace re-composition, PLT-R352; the commit at Return, Tab or Space, such as the ENG-R532 spelling, an English restore, ENG-R803, or a macro expansion, ENG-R1103; a restore on the Escape hotkey, PLT-R353) uses the keycode of the first character of its insertion, or else of the replaced text, that the current layout types on a key that is not one of these, and the A key only if there is none. This applies to every strategy that posts Unicode events (`backspaceReplace`, `selectReplace`, and the placeholder of 4.3). The triggering key itself still reaches the app after the edit, as the replay of the physical event on its own keycode, exactly once (P0-3). Rationale: Apple documents that frameworks may ignore the Unicode string and translate the keycode; keycode 0 is the A key, so tools that post keycode 0 make such apps type "a" for every character, which matches a prior-art report from iPhone Mirroring. With the triggering keycode, degraded output resembles the plain letters the user typed. Chromium (and so Electron) and WebKit derive the DOM `code` of a key event, and for a non-ASCII character also the legacy `keyCode`, from the virtual keycode (Chromium's public `keyboard_code_conversion_mac.mm`): a Unicode event posted on `kVK_Delete` reaches a web editor that acts on `keyCode` 8 as one more Backspace, so the edit deletes instead of inserting; on `kVK_Return` it reaches a chat composer that sends on `keyCode` 13 as Return, so the message is sent before the word is finished; on `kVK_Tab` it can move the focus. (Qt derives its key from the event's characters, so this mechanism does not apply to Qt apps.)
- **PLT-R406** Synthetic events carry no modifier flags except where a strategy requires them (Shift for `selectReplace`, Command for `paste`).
- **PLT-R407** Each synthetic key is a keyDown plus keyUp pair. Deletion uses the backspace key (`kVK_Delete`) without a Unicode string. Forward delete MUST NOT be used by any default or shipped rule unless its test proves it safe for that field. Rationale: prior-art users reported Outlook deleting the character after the caret and Google Docs pulling the next line up, the signature of a stray forward delete.
- **PLT-R408** Timing parameters (defaults; rules may override within the caps): `interEventDelayUs` between consecutive synthetic key pairs, default 0; `postDeleteSettleUs` between the last deletion and the first insertion, default 0; `firstEditDelayUs` before the first edit of a word that began within 300 ms of a focus change or click, default 0. Each value is capped at 50,000 µs. A job longer than 150 ms in total MUST be split at grapheme boundaries with held keys replayed between parts only if the rule sets `allowSplit`; otherwise the strategy's fallback is used.
- **PLT-R409** Pacing waits run on the `inject` thread using absolute deadlines (mach time). They never run on the tap thread.
- **PLT-R410** Verification modes: `echo` (always on, PLT-R323); `axReadback` (tests, diagnostics, and rules with `verifyAfterEdit: true`; bounded per PLT-R343); `human` (the guided test in section 12).

### 4.2 `backspaceReplace` (default)

| Aspect | Specification |
|---|---|
| When | Default for every context without a rule. Works in native Cocoa text, most Chromium/Electron web content, terminals (with pacing), most JVM and Qt apps |
| Mechanism | `deleteCount` backspace pairs, then the insertion as Unicode events per PLT-R404 |
| Failure modes | Inline completion consumes the first backspace (duplicated letter, see 4.3); apps that process events asynchronously reorder them (transposed letters); TUIs that read several keys in one read misparse mixed backspace and UTF-8 (lost letters); editor auto-pair logic deletes a closing bracket with the backspace; apps that ignore the Unicode payload type plain letters |
| Timing | Defaults 0 / 0 / 0. Rules add pacing for asynchronous targets |
| Verification | Echo; automated readback in tests; optional `verifyAfterEdit` |

### 4.3 Inline-completion handling

Applies to `backspaceReplace` and `selectReplace` through parameter `inlineCompletion`: `none` (default), `axSelection`, `placeholder`, `axSelectionThenPlaceholder`.

- **PLT-R420** `axSelection`: before deleting, the worker reads `AXSelectedTextRange` of the focused element with a 15 ms timeout (VERIFY value). If the selection length is greater than zero, it prepends one extra backspace, which removes the selected suggestion. On timeout or AX unavailability it uses the next option in the value (`placeholder` for `axSelectionThenPlaceholder`, otherwise none) and counts a health event.
- **PLT-R421** `placeholder`: the worker first inserts one zero-width placeholder character (candidate U+200B ZERO WIDTH SPACE; VERIFY per app), which replaces any selected suggestion and suppresses re-completion, then sends `deleteCount + 1` backspaces, then the insertion. This is correct whether or not a suggestion is showing, and needs no AX.
- **PLT-R422** `placeholder` is allowed only in a rule whose test demonstrates zero leftover placeholders over at least 1,000 randomised edits at burst typing speed, and MUST NOT be enabled by a global rule or a title-only rule. When AX readback is available, diagnostics MUST report fields where a leftover placeholder was detected. Rationale: the prior art applied an invisible-character trick through broad rules and users found stray characters.
- Rationale for the whole section: in browser address bars, Spotlight, and spreadsheet autocomplete, the suggested remainder is shown as selected text after the caret. The first synthetic backspace deletes that selection instead of the letter, so "a" + `s` becomes "aá" and "D" + `d` becomes "DĐ" (many prior-art reports across Chrome, Edge, Brave, Arc, Dia, Atlas, Firefox, Safari, Spotlight, Google Sheets and Excel).

### 4.4 `selectReplace`

| Aspect | Specification |
|---|---|
| When | Fields where synthetic backspace is mishandled but selection-then-type works. Prior-art users reported that a select-then-type rule fixed Telegram Web losing the first Vietnamese letter of a message |
| Mechanism | `deleteCount` presses of Shift+Left Arrow (layout-independent keycode), then the insertion, which replaces the selection |
| Failure modes | Terminals do not select; some editors extend by word or keep a selection anchored at the other end; cannot fix inline completion selected after the caret; brief visible selection; Shift+Left with no text field focused can move objects in design apps (gating PLT-R386 applies) |
| Timing | Defaults 0; `interEventDelayUs` if the app drops selection steps |
| Verification | Readback in tests; `verifyAfterEdit` recommended for new rules |

### 4.5 `axReplace`

| Aspect | Specification |
|---|---|
| When | Native Cocoa fields where key events are mishandled and AX is writable. Never for web content (no DOM input events, web app state diverges) and never for terminals |
| Mechanism | Set `AXSelectedTextRange` to the composition range ending at the caret, then set `AXSelectedText` to the insertion. Replacing the whole `AXValue` is forbidden (breaks undo, moves the caret, rewrites the whole field) |
| Failure modes | Undo grouping differs from typing; no key events for apps that listen to them; writes may silently do nothing; two AX round trips of latency |
| Timing | Each AX call 30 ms timeout |
| Verification | Mandatory bounded readback after each write. On mismatch or error, this field falls back to the rule's `fallback` for the rest of the focus session and a health event is recorded |

### 4.6 `paste` (last resort)

- **PLT-R460** `paste` is used only (a) for targets that ignore synthetic Unicode events but honour paste, after the user opts in for that app (shipped rules may offer it but MUST set `requiresUserOptIn: true`), or (b) for long text per section 4.8 when a rule allows it.
- **PLT-R461** Full clipboard preservation, executed entirely on the `inject` thread:
  1. Snapshot every `NSPasteboardItem` of the general pasteboard with every type and its data, plus `changeCount`. If any item cannot be read within 100 ms, is a file promise or lazily provided data that cannot be materialised, or the total exceeds 10 MB, abort `paste` and use the fallback strategy. Never destroy what cannot be restored.
  2. `clearContents`, then write one item with `public.utf8-plain-text` plus the marker types `org.nspasteboard.TransientType`, `org.nspasteboard.ConcealedType` and `org.nspasteboard.AutoGeneratedType`, so clipboard managers skip it. Record the new `changeCount`.
  3. Send the deletions, then Command+V using the keycode that produces "v" in the current layout.
  4. Release held keys (the key-ordering guarantee covers only steps 3 and earlier), then wait `restoreDelayMs` (default 400 ms; VERIFY per client because remote clients sync asynchronously).
  5. Restore all saved items and types only if `changeCount` still equals the value from step 2. If it changed, the user copied something new: do not restore, record a health event.
  6. Consecutive paste jobs within the restore window coalesce: restore once, after the last one.
- **PLT-R462** Failure modes to document in the UI when the user opts in: the target reads the clipboard after restore and pastes old content; clipboard sync disabled in the remote client; apps that block synthetic Command+V. VERIFY: thread-safety of `NSPasteboard` off the main thread; if not safe, hop to main asynchronously while the worker waits on its own condition with a timeout.
- Rationale: the prior art's paste injection overwrote the clipboard without restoring it and blocked the tap for about 0.6 s per keystroke.

### 4.7 `passThrough`

Keys flow unchanged, the engine is not fed, the composition is reset. Used for EN mode, paused states, secure fields, and rules for games, remote desktops, VMs and iPhone Mirroring.

### 4.8 Long text (macros)

- **PLT-R480** Insertions longer than `longTextThreshold` (default 64 graphemes) MAY use chunks of up to 20 UTF-16 units when the rule sets `allowMultiCharEvents: true`; otherwise one grapheme per event. Insertions over 2,000 graphemes use `paste` only if the user opted in for that app; otherwise chunked Unicode. Maximum macro expansion: 4,000 graphemes. The liveness ceiling for macro jobs is 1 s instead of 150 ms.

### 4.9 Not in v1

- `markedText`: exists only together with an IMKit bundle (PLT-R207).
- `overlayPreedit`: composition drawn in {{AppName}}'s own floating panel near the caret and committed as one insertion at the word boundary. Candidate for hostile targets (terminal TUIs, remote desktops) in a later version; needs caret geometry from AX.

### 4.10 Summary

| Strategy | Use when | Main risk | Default timing | Verified by |
|---|---|---|---|---|
| backspaceReplace | Default | Inline completion, async apps | 0 / 0 / 0 | Echo, test readback |
| + axSelection | Completion fields with readable AX | AX latency | 15 ms AX timeout | Test readback |
| + placeholder | Completion fields without AX | Leftover invisible char | 0 | 1,000-edit test, diagnostics |
| selectReplace | Backspace mishandled | Selection semantics differ | 0 | Test readback |
| axReplace | Native fields, keys mishandled | Silent no-op, undo | 30 ms per call | Mandatory readback |
| paste | Opt-in, remote/VM, long text | Clipboard timing | 400 ms restore | Test readback, changeCount guard |
| passThrough | EN, paused, hostile targets | None | n/a | n/a |

### Acceptance criteria (section 4)

- On a local test page with JavaScript inline autocomplete, Chromium, Safari and Firefox produce "á", "đ", "ô" correctly with the shipped completion rules, 1,000 randomised words each, zero duplicates and zero leftover placeholders.
- Clipboard preservation test: a pasteboard holding text, RTF, PNG and a file URL in two items is byte-identical after 100 paste jobs; a clipboard manager observing the pasteboard records none of the injected strings.
- No shipped rule emits forward delete (static check over the rules file).
- Edits are minimal: "nguyen" + `s` produces exactly 2 backspaces and 2 inserted characters.

## 5. Compatibility rule system

### 5.1 Principles

- **PLT-R501** Application code MUST NOT contain per-app branches. All per-app behaviour comes from the shipped rules resource or user overrides; code implements only generic strategies, matchers and parameters. A CI lint MUST fail the build if a bundle-ID-shaped string literal appears outside the rules resource, test fixtures and the conflicting-apps list. Rationale: a 3,269-line per-app special-case file with 91 hard-coded bundle IDs never converged; about half of prior-art bug reports were app-specific.
- **PLT-R502** Matching MUST NOT use localized UI strings (AX titles, descriptions, placeholders, menu titles). `titlePattern` is allowed only in shipped rules, only together with `bundleIds`, and is discouraged; user overrides cannot use it (consistent with `03-product.md`, which excludes user-facing window-title rules). Rationale: the prior art matched English strings such as a field description and applied a spreadsheet title rule to every app. Terminology: a "compatibility profile" in `03-product.md` is the resolved rule decision of this section.
- **PLT-R503** Rules ship as `compat-rules.json` inside the app bundle, validated against a JSON Schema in CI and at load. An invalid file MUST NOT crash the app: it loads the last embedded known-good defaults (compiled-in minimal ruleset) and reports a health event.
- **PLT-R504** No remote rule fetching in v1. Rules change only through signed app updates. Rationale: privacy, reproducibility, and every rule having a test.
- **PLT-R505** Every shipped rule MUST have provenance and a test reference; CI fails otherwise.
- **PLT-R506** Every shipped rule has `reviewBy` (at most 12 months ahead). CI warns when a date has passed and blocks a release when it passed more than 30 days ago.

### 5.2 Context available to matchers

From the focus snapshot (PLT-R383): bundle ID, app version, macOS version, engine fingerprint, app category (`LSApplicationCategoryType`), AX role, subrole, identifier, DOM class list, nearest ancestor roles (up to 6 levels, computed on the `ax` thread on focus change), editable flag, document URL of the focused web area when AX exposes it (evaluated in memory only, never stored or logged), window title (only for bundles with a `titlePattern` rule, evaluated in memory only).

### 5.3 Engine fingerprinting

- **PLT-R510** The `ax` thread computes an engine fingerprint once per (bundle path, `CFBundleVersion`) by inspecting the bundle and caches it: `electron` (contains `Electron Framework.framework`), `chromium` (a `* Framework.framework` with a `* Helper (Renderer).app` helper), `cef` (`Chromium Embedded Framework.framework`), `gecko` (contains `libxul.dylib`), `jvm` (bundled Java runtime), `qt` (`QtCore.framework`), `catalyst`, `ios` (iOS app on Apple silicon), `webkitBrowser` (Safari and Safari Technology Preview by bundle ID in rules), else `native`. VERIFY each heuristic against current builds.
  Rationale: new Chromium browsers (Helium, Atlas, Dia, Comet) then get correct behaviour without a release; prior-art users had to request that each new browser be added to a list.

### 5.4 Schema

Top-level document:

```json
{
  "schemaVersion": 1,
  "rulesetVersion": "2026.11.0",
  "defaults": {
    "strategy": "backspaceReplace",
    "params": { "unicodeChunk": 1, "interEventDelayUs": 0, "postDeleteSettleUs": 0,
                "firstEditDelayUs": 0, "inlineCompletion": "none" },
    "fallback": ["passThrough"],
    "defaultMode": "inherit",
    "requireTextFocus": "byEngine",
    "verifyReentry": "whenReadable"
  },
  "bundleGroups": {
    "terminals": ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                  "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty",
                  "org.alacritty"]
  },
  "conflictingInputApps": ["..."],
  "secureInputHints": [{ "bundleId": "com.apple.Terminal", "hintKey": "terminal.secureKeyboardEntry" }],
  "rules": []
}
```

Rule fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string, dotted, unique | yes | Stable; referenced by tests, overrides and diagnostics |
| `summary` | string | yes | One line, English |
| `match.bundleIds` / `match.bundleGroup` | [string] / string | no | Exact bundle IDs |
| `match.engines` | [enum] | no | From PLT-R510 |
| `match.appCategories` | [string] | no | `LSApplicationCategoryType` values |
| `match.appVersion` | {min, max} | no | Semver-ish comparison on `CFBundleShortVersionString` |
| `match.macOS` | {min, max} | no | |
| `match.ax.roles`, `subroles`, `identifiers`, `domClasses`, `ancestorRoles` | [string] | no | Any-of within a field, all-of across fields |
| `match.ax.editable` | bool | no | |
| `match.web.urlPrefixes` | [string] | no | Requires AX document URL; never logged |
| `match.titlePattern` | regex string | no | Requires `bundleIds`; compiled at load; max 200 chars |
| `action.strategy` | enum | yes | `backspaceReplace`, `selectReplace`, `axReplace`, `paste`, `passThrough` |
| `action.params` | object | no | Keys from section 4 plus `allowMultiCharEvents`, `allowSplit`, `longTextThreshold`, `restoreDelayMs`, `verifyAfterEdit` |
| `action.fallback` | [enum] | no | Used only when the primary fails detectably before or during execution (AX error, readback mismatch) |
| `action.defaultMode` | `inherit`, `vi`, `en` | no | First-seen mode for per-app memory |
| `action.requireTextFocus` | `never`, `whenKnown`, `always`, `byEngine` | no | PLT-R386 |
| `action.axEnable` | `none`, `manual` | no | PLT-R385 |
| `action.overlay` | bool | no | Observe this app's AX focus even when not frontmost |
| `action.requiresUserOptIn` | bool | no | Rule is offered in the UI but inactive until the user enables it |
| `action.engineContext` | `general`, `code` | no | Passed to the engine as `appContext` (ENG-R850): `code` restores shell words such as `tar`, `less` in terminals and IDEs. Default `general` |
| `action.features` | object | no | Per-context feature switches defined by the engine and product specs: `autoCapitalize`, `macros`, `englishRestore`, `restoreHotkey` (all default true except `autoCapitalize`, which is a later feature) |
| `provenance.reason` | string | yes | Symptom and cause in one or two sentences |
| `provenance.evidence` | [ {type, ref} ] | yes | Own issue tracker links, test reports |
| `provenance.tested` | [ {app, appVersion, macOS, date, result} ] | yes | At least one passing entry |
| `provenance.notes` | string | no | Open VERIFY items |
| `provenance.addedIn`, `reviewBy` | string, date | yes | |
| `test.scenario` | string | yes | Scenario ID (section 13.2) |
| `test.automation` | `automated`, `manual` | yes | Manual tests must have a compat-matrix row |

### 5.5 Resolution

- **PLT-R520** Candidates are rules whose present match fields all match. Specificity score: `ax.identifiers` or `ax.domClasses` +16; `ax.roles`, `ax.subroles` or `ax.ancestorRoles` +8; `web.urlPrefixes` +8; `titlePattern` +4; `bundleIds` +4; `engines` +2; `appCategories` +1. The highest score wins, with one exception: a candidate that matches by `appCategories` and whose action is `passThrough` (the games rule) wins over every candidate whose score comes only from `engines`, so a game built on JVM, Electron, CEF or Chromium passes keys through instead of getting its engine's strategy (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md). The winning rule's `action` is applied over `defaults` (no merging across several rules).
- **PLT-R521** CI MUST fail if two shipped rules have identical match signatures. At runtime an unexpected tie resolves to the lexicographically smaller `id` and records a health event.
- **PLT-R522** User overrides use the same schema with source `user` and always outrank shipped rules.
- **PLT-R523** Resolution runs on the `ax` thread when the focus context changes, never per keystroke.

### 5.6 Example rules

Bundle IDs below are illustrative; each MUST be checked against the installed app's `Info.plist` when its test is written.

```json
[
  {
    "id": "browser.chromium.addressBar",
    "summary": "Chromium-family address and command bars with inline autocomplete",
    "match": {
      "engines": ["chromium"],
      "ax": { "roles": ["AXTextField"], "ancestorRoles": ["AXToolbar"] }
    },
    "action": {
      "strategy": "backspaceReplace",
      "params": { "inlineCompletion": "axSelectionThenPlaceholder" },
      "features": { "autoCapitalize": false }
    },
    "provenance": {
      "reason": "Selected inline suggestion absorbs the first backspace: 'a'+'s' gives 'aá', 'd'+'d' gives 'dđ'.",
      "evidence": [{ "type": "scenario", "ref": "compat/inline-completion-local-page" }],
      "tested": [{ "app": "Google Chrome", "appVersion": "VERIFY", "macOS": "27.1", "date": "VERIFY", "result": "pass" }],
      "notes": "VERIFY that the omnibox is exposed to AX without enabling renderer accessibility; VERIFY Arc command bar roles.",
      "addedIn": "1.0.0", "reviewBy": "2027-11-01"
    },
    "test": { "scenario": "browser.chromium.addressBar", "automation": "automated" }
  },
  {
    "id": "web.googleSheets.cellEditor",
    "summary": "Google Sheets cell autocomplete in Chromium browsers",
    "match": {
      "engines": ["chromium"],
      "web": { "urlPrefixes": ["https://docs.google.com/spreadsheets/"] }
    },
    "action": {
      "strategy": "backspaceReplace",
      "params": { "inlineCompletion": "placeholder", "firstEditDelayUs": 8000 }
    },
    "provenance": {
      "reason": "Column autocomplete selects the suggested remainder ('D'+'d' gives 'DĐức'); first letter lost when the cell enters edit mode.",
      "evidence": [{ "type": "scenario", "ref": "compat/sheets-autocomplete" }],
      "tested": [{ "app": "Google Chrome", "appVersion": "VERIFY", "macOS": "27.1", "date": "VERIFY", "result": "pass" }],
      "notes": "Requires AX document URL; without it this rule never matches. VERIFY firstEditDelayUs. Placeholder requires the 1,000-edit test (PLT-R422).",
      "addedIn": "1.0.0", "reviewBy": "2027-05-01"
    },
    "test": { "scenario": "web.googleSheets.cellEditor", "automation": "manual" }
  },
  {
    "id": "terminal.default",
    "summary": "Terminal emulators: one key per read for TUIs, no auto-capitalisation",
    "match": { "bundleGroup": "terminals" },
    "action": {
      "strategy": "backspaceReplace",
      "params": { "unicodeChunk": 1, "interEventDelayUs": 1500, "postDeleteSettleUs": 4000 },
      "requireTextFocus": "never",
      "engineContext": "code",
      "features": { "autoCapitalize": false, "restoreHotkey": false }
    },
    "provenance": {
      "reason": "TUIs (Claude Code, Kiro CLI) lost or appended letters when backspaces and UTF-8 arrived in one read.",
      "evidence": [{ "type": "scenario", "ref": "compat/terminal-tui" }],
      "tested": [{ "app": "Terminal", "appVersion": "VERIFY", "macOS": "27.1", "date": "VERIFY", "result": "pass" }],
      "notes": "Initial pacing values are hypotheses. VERIFY with an Ink-based TUI, zsh-autosuggestions, tmux over ssh.",
      "addedIn": "1.0.0", "reviewBy": "2027-05-01"
    },
    "test": { "scenario": "terminal.default", "automation": "automated" }
  },
  {
    "id": "design.shortcutHeavy",
    "summary": "Design and video apps where letters are tool shortcuts",
    "match": {
      "bundleIds": ["com.adobe.illustrator", "com.adobe.Photoshop", "com.seriflabs.affinitydesigner2",
                    "com.bohemiancoding.sketch3", "com.figma.Desktop", "com.blackmagic-design.DaVinciResolve"]
    },
    "action": {
      "strategy": "backspaceReplace",
      "defaultMode": "en",
      "requireTextFocus": "whenKnown"
    },
    "provenance": {
      "reason": "Telex double letters produced a backspace that deleted the selected shape when no text field had focus.",
      "evidence": [{ "type": "scenario", "ref": "compat/design-shortcuts" }],
      "tested": [{ "app": "Affinity Designer 2", "appVersion": "VERIFY", "macOS": "27.1", "date": "VERIFY", "result": "pass" }],
      "notes": "VERIFY which of these apps expose an editable AX role while editing a text frame; where they do, consider requireTextFocus=always.",
      "addedIn": "1.0.0", "reviewBy": "2027-05-01"
    },
    "test": { "scenario": "design.shortcutHeavy", "automation": "manual" }
  },
  {
    "id": "remote.passThrough",
    "summary": "Remote desktop, VM and iPhone Mirroring clients forward keycodes, not text",
    "match": {
      "bundleIds": ["com.microsoft.rdc.macos", "com.apple.ScreenSharing", "com.apple.ScreenContinuity",
                    "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
                    "com.philandro.anydesk", "com.teamviewer.TeamViewer"]
    },
    "action": {
      "strategy": "passThrough",
      "defaultMode": "en",
      "fallback": [],
      "features": { "macros": false, "restoreHotkey": false }
    },
    "provenance": {
      "reason": "Clients translate keycodes; injected text arrives as wrong letters ('a' for everything) or nothing.",
      "evidence": [{ "type": "scenario", "ref": "compat/remote-clients" }],
      "tested": [{ "app": "Screen Sharing", "appVersion": "VERIFY", "macOS": "27.1", "date": "VERIFY", "result": "pass" }],
      "notes": "VERIFY bundle IDs (iPhone Mirroring, Windows App). Users may opt into the 'paste' strategy per app.",
      "addedIn": "1.0.0", "reviewBy": "2027-11-01"
    },
    "test": { "scenario": "remote.passThrough", "automation": "manual" }
  }
]
```

### 5.7 Rule tests

- **PLT-R530** A scenario file (JSON) specifies: target bundle ID; setup steps (launch, open URL, seed history to create autocomplete, focus field); key script as physical key names with timing profile; expected field text; readback method (`ax`, `webdriver`, `terminalCapture`, `human`). Scenarios run in `CompatHarness` on the self-hosted runner (section 13.2).
- **PLT-R531** Manual scenarios MUST have a row in `compat/matrix.json` with date, app version, macOS build and tester, not older than 90 days at release time for Tier 1 apps (section 13.3, tiers per `03-product.md` PRD-R39).

### 5.8 User overrides

- **PLT-R540** The override mechanism MUST support, per app: strategy (`backspaceReplace`, `selectReplace`, `axReplace` for native apps, `paste` with a clipboard explanation, `passThrough`), pacing (0 to 10 ms), `inlineCompletion`, and scope "this app" or "only this kind of field" (adds the focused role, subrole, identifier or DOM classes to the match), plus "reset to automatic". How much of this is exposed is owned by `03-product.md`: PRD-R36 allows at most three plain choices under Advanced in the app's detail sheet; the full parameter set is reached only through the guided test in section 12 (which creates overrides automatically) and through importing rule JSON.
- **PLT-R541** Overrides are stored in `rule-overrides.json`, listed in Settings with "set by you on <date>", included in exports, and included as rule JSON in diagnostics reports for the reported app so maintainers can promote them to shipped rules.

### Acceptance criteria (section 5)

- The lint finds no bundle-ID literals in application code.
- Every shipped rule validates, has provenance, a `reviewBy` date and a scenario; CI proves it.
- A Chromium browser unknown to the rules file (for example a freshly installed Helium build) gets `engines: ["chromium"]` rules without an app update.
- Changing a user override takes effect on the next keystroke without restart.

## 6. Known hard cases

Symptoms paraphrase user reports against the prior art. Approaches are the v1 plan; every row needs its scenario to pass before release.

| Target | Reported symptoms | Likely cause | Chosen approach | Status |
|---|---|---|---|---|
| Chromium address bars (Chrome, Edge, Brave, Arc, Dia, Atlas, Helium, Vivaldi, Opera, Cốc Cốc) | "as" gives "aá", "dd" gives "dđ", "canhs" gives "caánh" in Arc's command bar; unstable after the new-tab shortcut; a leading vowel duplicated | Inline suggestion is selected after the caret and absorbs a backspace | Rule `browser.chromium.addressBar`: `axSelectionThenPlaceholder`; auto-capitalisation off in URL fields | VERIFY AX exposure of the omnibox and Arc's bar |
| Safari address bar | VNI "ca6u" gives "caấu" | Same | `axSelection` (WebKit exposes AX natively) | VERIFY |
| Firefox URL bar | "Có" gives "Coó" | Same | `axSelectionThenPlaceholder` | VERIFY Gecko AX availability |
| Spotlight, Raycast, Alfred | "books" gives "boôooks", "cố" gives "coố", intermittent; Raycast ignores the remembered mode; Escape failed to close Spotlight | Inline completion; non-activating panels not seen as the focused app | `overlay: true` rules; focus authority PLT-R381; `axSelection` for Spotlight; Escape pass-through PLT-R353 | VERIFY on macOS 26 and 27 (a competitor shipped a macOS 27 Spotlight-specific fix) |
| Google Sheets, Excel | "Đức" gives "DĐức" with column autocomplete; first letter lost in Sheets on Safari when the cell is not yet in edit mode; Excel cell content erased; Excel sheet-tab rename accumulates ("dữ liệuiêueưu") | Autocomplete selection; edit-mode transition drops early events; sheet-tab editor ignores synthetic backspace | Sheets: rule with `placeholder` in Chromium, `axSelection` in Safari, `firstEditDelayUs`; Excel cell editor: `axSelectionThenPlaceholder`; sheet tab: `selectReplace` or `axReplace` per test | VERIFY all |
| Word, PowerPoint, Outlook, Google Docs | Outlook deletes the character after the caret; Docs pulls the next line up | Stray forward delete | Default `backspaceReplace`, forward delete banned (PLT-R407) | VERIFY Office AX and Word AutoComplete |
| LibreOffice | "Nguyễn" gives "Ngễuyn" | Asynchronous event processing reorders | Pacing `interEventDelayUs` 1000, `postDeleteSettleUs` 2000 | VERIFY values |
| Electron apps (VS Code, Slack, Discord, Notion, Obsidian, Cursor) | Mostly fine; users want VS Code's integrated terminal treated differently from the editor | Web editors handle synthetic keys; panel identity needs AX | Default strategy. Do not enable accessibility by default. Per-panel rules only if AX is available without side effects | VERIFY VS Code screen-reader-mode side effect of `AXManualAccessibility` |
| Terminals (Terminal, iTerm2, Ghostty, Warp, WezTerm, kitty) | Claude Code TUI: "muốn" leaves "m", extra vowels appended; Kiro CLI "chaof" gives "cha"; tmux over ssh garbled; Warp and WebStorm terminal duplicated vowels | TUIs misparse several keys in one read; keystrokes are bytes; Secure Keyboard Entry blocks taps | Rule `terminal.default` (pacing, no auto-capitalisation, no AX gating because AX is unreliable; Warp reports caret 0); Secure Keyboard Entry hint | VERIFY pacing per TUI |
| JetBrains IDEs | Duplicated vowels; IDE froze with the prior art | Asynchronous event handling; slow Java AX blocked the prior art's main thread | `engines: ["jvm"]` rule with pacing 1000 / 2000 µs, `requireTextFocus: never`, `engineContext: code`; AX circuit breaker | VERIFY |
| Figma, Adobe, Affinity, Sketch, DaVinci Resolve | Double letters delete the selected shape; holding Z or Space lags; Space delayed after playback even with Vietnamese off | Shortcut letters; slow tap on the main run loop | Rule `design.shortcutHeavy`; tap thread design; autorepeat pass-through | VERIFY AX text roles per app |
| Games, full-screen apps | Input lag; transforms in game controls | Tap overhead; keycode-driven input | `appCategories: ["public.app-category.games", ...]` rule: `passThrough`, `defaultMode: en` | Manual |
| Remote desktop, VMs, iPhone Mirroring | Vietnamese impossible or every character becomes "a"; remembered mode not restored on leaving iPhone Mirroring | Keycode forwarding; keycode 0 | Rule `remote.passThrough`; per-app memory; optional user opt-in `paste`; advise using the remote, guest or iPhone keyboard input | VERIFY per client; VERIFY iOS hardware keyboard Vietnamese input |
| Password fields | A macOS password dialog received extra characters; a browser holding secure input blocked Vietnamese until a tab switch | Field without secure input; long-held secure input | `AXSecureTextField` pass-through (PLT-R387); holder naming (PLT-R396) | Automated |
| Zalo, Messenger, Telegram | Zalo search garbled when typing fast; Telegram Web drops the first Vietnamese letter; Telegram native deletes "ủa" on Space; Messenger web on Chromium loses a letter of "ươ" | Ordering; web composer handling of the first edit | Ordering guarantee PLT-R311; Telegram Web: `selectReplace` rule scoped by URL; others default until reproduced | VERIFY Zalo engine fingerprint and each symptom |
| Custom text views (Sublime Text, Emacs.app, MacVim) | Not reported; risk introduced by this spec | `whenKnown` gating may misclassify a custom view | Seed rules with `requireTextFocus: never`; "paused: no text field detected" shown in the menu with a one-click override | VERIFY |

## 7. Permissions

### 7.1 Required permissions

- **PLT-R701** Accessibility is required: active keyboard tap, posting events, AX focus queries. Check: `AXIsProcessTrusted()`, which follows the switch while the app runs; it alone decides whether Accessibility is missing. `CGPreflightPostEventAccess()` and `CGPreflightListenEventAccess()` keep the answer they had when the process started (Apple DTS on the Apple developer forums, threads 727984 and 720840): they are recorded in diagnostics and never by themselves report a permission as missing. Posting events is part of the Accessibility grant (WWDC19 session 701: synthesized events and a modifying tap need the Accessibility authorization); a posting path that fails anyway is caught by echo loss (PLT-R323, PLT-R730). Pa, 2026-11-14: on macOS 27.2 the permission screen kept waiting after Device Control and Data Access was switched on. Readiness also required the post preflight, which keeps its launch-time answer (a unit test reproduces that half); the most likely reason the screen passed only after Input Monitoring was switched on is the relaunch macOS offers after that change, which refreshed the preflight, so it looked as if Input Monitoring were required. That second half is an inference pending `scripts/vm/tap-permission.sh` (docs/runbooks/vm-test-lab.md section 11) and checklist T2.2 on macOS 27.2. Location: System Preferences > Security & Privacy > Privacy > Accessibility on macOS 12; System Settings > Privacy & Security > Accessibility on macOS 13 to 26; renamed **"Device Control and Data Access"** on macOS 27, as stated in vendor support documents from Microsoft, Logitech and Synergy (September to October 2026). The label (Vietnamese "Điều khiển thiết bị và truy cập dữ liệu") is in Apple's localization tables of macOS 27.2 (decision 0005 Q37). VERIFY the label as displayed, the system prompt text (reported as "would like to control this Mac and access your data") and the System Settings deep-link URL on a macOS 27.x machine.
- **PLT-R702** Input Monitoring (unchanged name on macOS 27 per the same vendor documents) MUST be requested only when the tap needs it: the active tap cannot be created while Accessibility is granted, and Input Monitoring is missing both by `CGPreflightListenEventAccess()` (the answer at launch) and by the live check, a listen-only key tap created and released at once (a passive tap never holds a key back). The live check runs only after such a failure, because creating a key tap can make macOS prompt. Detection needs no typing: the tap is created as soon as `AXIsProcessTrusted()` turns true (polled every second on the permission screen, PLT-R711); the screen then shows the Input Monitoring row (PLT-R705) and asks macOS once with `CGRequestListenEventAccess()` to list the app and show its prompt. A `ready` replaced during its own delivery (the tap it allowed failed at once) MUST NOT move the screen on: the host forwards only the monitor's latest status, and a flow already moved by that grant returns to the permission screen (PRD-R40). WWDC19 session 701: a listen-only tap needs Input Monitoring, a modifying tap needs Accessibility; a created tap that receives no key events is not documented TCC behaviour and is not detected. VERIFY on 12 and 27 with `scripts/vm/tap-permission.sh` (docs/runbooks/vm-test-lab.md section 11) and on 15 and 26 by hand whether an Accessibility-trusted process creates the active keyboard tap and receives keys without Input Monitoring; if a version needs Input Monitoring for that tap up front, the row is shown from the start on it. Rationale: every extra prompt costs trust.
- **PLT-R703** No other permissions: no Automation (Apple Events), Screen Recording, Full Disk Access, Contacts, Bluetooth, local network, or camera.
- **PLT-R704** Pane names and deep links MUST come from an OS-version-keyed table in localized resources; UI code never hard-codes them. The table covers System Preferences (macOS 12: other pane names, `com.apple.preference.*` anchors, Login Items under Users & Groups) and System Settings (macOS 13 and later).
- **PLT-R705** The permission screen MUST show one row per permission the tap needs, named as System Settings names it (PLT-R704 table, macOS language) with its live state, and its primary button MUST name and open exactly the pane of the first permission still missing (Accessibility first). The Input Monitoring row stays, as granted, once its need cleared on that screen. A switch that is on in System Settings is never met by a "permission missing" that does not say which one (Pa, 2026-11-14).

### 7.2 Onboarding and app location

- **PLT-R710** Before requesting permissions, the app MUST check that it runs from `/Applications` or `~/Applications` and is not translocated. If not, it offers to move itself and relaunch, and does not request permissions from the original location. Rationale: a grant recorded for a translocated or temporary path does not follow the app to its final location, so users end up with an entry that is switched on but does nothing (VERIFY on current macOS).
- **PLT-R711** Flow: explain in plain words why the permission is needed; open the pane with a deep link; poll the trust state every 1 s while onboarding is visible (maximum 5 minutes); show success; let the user try a built-in test field ("tieengs Vieetj" shows "tiếng Việt").
- **PLT-R712** If Input Monitoring is required, offer "Relaunch now" with its row: macOS offers to quit and reopen an app after an Input Monitoring change, and the launch-time preflight sees the grant only after a relaunch. Where the live check (PLT-R702) already sees the grant, the need clears without a relaunch (PLT-R731).

### 7.3 Live permission health

- **PLT-R720** Permission states: `granted`, `denied`, `unknown`. Derived health: `ready`, `noPermission`, `stale` (was granted for this exact signing identity, now failing, typically after a macOS update), `secureInput`, `paused(reason)`.
- **PLT-R721** Poll every 2 s while not ready and every 30 s while ready; check immediately on wake, session activation and menu open.

### 7.4 Fail-open

- **PLT-R730** On any signal that posting no longer works (Accessibility trust revoked, echo loss PLT-R323; the post preflight keeps its launch-time answer and is not such a signal, PLT-R701), the tap MUST stop swallowing events within the same callback, replay held events, reset the composition, then disable and remove the tap, and enter `failOpen` with guidance. {{AppName}} MUST never leave the keyboard blocked.
- **PLT-R731** When permission returns, the host recreates the tap and returns to `ready` without a relaunch where the OS allows it.

### 7.5 Re-grant guidance

- **PLT-R740** In `stale`, guidance MUST say: open the pane, remove {{AppName}} with the minus button, add it again; or press "Reset permission", which runs `tccutil reset Accessibility vn.kal.{{app-slug}}` and prompts again. User-initiated only, never automatic. `tccutil reset` scoped to one bundle ID works without administrator rights on macOS 15 and 26 (VERIFY on macOS 12 to 14 and on macOS 27: the service name may differ after the pane rename).
- **PLT-R741** Guidance MUST NOT suggest `sudo tccutil reset Accessibility` without a bundle ID (it resets every app).

### 7.6 Signing and permission persistence

- **PLT-R750** Every user-facing build MUST be signed with Pa's Developer ID Application certificate (individual team), with hardened runtime and secure timestamp, notarized and stapled. The designated requirement stays the default (bundle identifier plus team anchor). Bundle ID and Team ID MUST never change. Rationale: TCC grants follow the designated requirement; ad-hoc signatures change with every build, which made the prior art re-ask permissions and show Secure Input errors after updates.
- **PLT-R751** Development builds MUST use bundle ID `vn.kal.{{app-slug}}.dev` and Apple Development signing, so their grants never collide with release grants.
- **PLT-R752** Updates replace the app in place at the same path with the same identity; section 13.5 tests that trust persists.

### 7.7 Managed Macs

- **PLT-R760** Documentation for IT administrators MUST list the PPPC services needed (Accessibility, PostEvent, ListenEvent) with the code requirement, and note that on macOS 27 Accessibility management moved to Declarative Device Management and appears under "Device Control and Data Access". VERIFY against Apple's MDM documentation.

### Acceptance criteria (section 7)

- Fresh install on macOS 12, 15, 26 and 27: one permission prompt path, typing works within 2 s of granting, no relaunch unless Input Monitoring is needed.
- Revoking Accessibility while typing: every subsequent key reaches the app untransformed; the menu shows `noPermission` within 2 s.
- Updating through Sparkle preserves the grant on all three OS versions.
- Running from the mounted DMG triggers the move offer, never a permission request.

## 8. Threading and performance budgets

### 8.1 Budgets

Targets are for Apple silicon (M1 class). Intel targets are 1.5 times the values. "Gate" values fail CI.

| ID | Metric | Definition | Target | Gate |
|---|---|---|---|---|
| T1 | Callback duration | Tap callback entry to return, all event kinds | p50 ≤ 15 µs, p99 ≤ 60 µs, p99.9 ≤ 250 µs | p99 ≤ 100 µs |
| T2 | Decide to posted | Callback entry to return of the last `CGEventPost` of the job; default strategy, no pacing | p50 ≤ 0.5 ms, p99 ≤ 2 ms | p99 ≤ 3 ms |
| T3 | Decide to posted with `axSelection` | Same, including the AX read | p50 ≤ 2 ms, p99 ≤ 8 ms | p99 ≤ 15 ms |
| T4 | End-to-end delta | Probe text-view update time of an edit minus pass-through baseline for the same timing profile | p50 ≤ 2 ms, p99 ≤ 6 ms | p99 ≤ 10 ms |
| T5 | Held wait | Time a held event waits before replay | p99 ≤ job duration + 1 ms | Zero flushes in the normal profile |
| T6 | Focus refresh | AX notification to snapshot published | p95 ≤ 30 ms | p95 ≤ 60 ms |
| C1 | Idle CPU | 5 minutes idle, menu closed | ≤ 0.1 % average, ≤ 1 wakeup/s | ≤ 0.3 % |
| C2 | Typing CPU | 10 keys/s for 5 minutes | ≤ 1.5 % of one core | ≤ 3 % |
| M1 | Memory at rest | `phys_footprint` 10 minutes after launch, windows closed | ≤ 35 MB | ≤ 50 MB |
| M2 | Soak growth | 8 hours of synthetic typing | ≤ 2 MB/h, no monotonic growth | ≤ 5 MB/h |
| S1 | Ready after launch | Process start to tap active (permissions granted) | ≤ 300 ms | ≤ 1 s |

VERIFY M1 against a measured SwiftUI menu-bar baseline in the first sprint. After that, no budget may be loosened by more than 25 % without Pa's sign-off.

This table is the single source for platform performance gates; `04-quality-release.md` QA-R14 references it instead of repeating numbers, and the engine's own budget is ENG-R1230. The "Gate" column is release-blocking; the "Target" column is what the design aims for.

### 8.2 Instrumentation

- **PLT-R801** Always-on, content-free, lock-free histograms (fixed memory, log2 buckets) for T1, T2/T3, echo round trip, T5, AX call duration aggregated per bundle ID, flush count, tap timeouts, fallback activations.
- **PLT-R802** Signposts (`os_signpost`) around callback, job execution and AX calls in all builds; zero cost when not recording.
- **PLT-R803** No timer in steady state fires more often than every 2 s; all timers set leeway of at least 10 %; no busy waiting anywhere.

### 8.3 Built-in latency probe

- **PLT-R810** Diagnostics MUST offer "Run typing latency test": an in-app window with a plain text view; an in-process driver posts physical-like events (unmarked for the pipeline, tagged separately so user metrics exclude them) with three timing profiles (normal 120 ms, fast 40 ms, burst 5 ms); the probe records receipt and text-change times and reports T2 and T4 percentiles. Results are included in the diagnostics report.

### 8.4 CI measurement

- **PLT-R820** Hosted CI (no permissions): engine microbenchmarks; pipeline benchmark with fake poster and fake AX measuring T1 and job construction.
- **PLT-R821** Self-hosted runner (permissions granted to the stable-signed test build): T2 to T6, C1, C2, M1, M2 using `CompatHarness`; CPU and wakeups from `proc_pid_rusage` deltas (no root needed).
- **PLT-R822** Regression gate: fail if a gated metric exceeds its gate or exceeds the stored baseline by more than 25 %. Baselines live in the repository and change only in reviewed commits.

## 9. Privacy and security

- **PLT-R901** Data classes: Content (keystrokes, composed text, field values, window titles, URLs, macro bodies, clipboard data); Metadata (bundle IDs, app versions, AX roles, rule IDs, timings, counters); Settings. Content MUST NOT be written to logs or disk except (a) user-authored settings and macros, (b) the time-boxed capture (PLT-R905).
- **PLT-R902** The logging API MUST be typed: fields accept enumerated metadata types; strings only from static literals; dynamic strings only through an explicit redaction wrapper that hashes (salted per install) or drops them. A lint forbids string interpolation into log calls. `os_log` usage keeps the default private redaction for dynamic values.
- **PLT-R903** Logs live in `~/Library/Logs/{{AppName}}/` (directory 0700, files 0600), JSON lines, rotation 5 files of 1 MB, retention 14 days. If `{{AppName}}` contains non-ASCII characters, all folder names in this document use `{{app-slug}}` instead; the choice is permanent.
- **PLT-R904** There is no verbose or debug mode that logs content. Rationale: the prior art's debug mode wrote keystroke-level content to a plain file in the home folder, never deleted it, and users were asked to paste it into public issues.
- **PLT-R904A** Dev recorder: the one exception to PLT-R901, PLT-R904 and PLT-R911, for development builds only (the product owner's decision of 2026-11-14, `docs/decisions/0007-dev-recorder.md`). Builds of the Debug configuration (the development bundle ID and the Apple Development signature; never notarized, never distributed, never built by `scripts/build-release.sh`) record typing continuously, so that a bug the product owner meets while dogfooding can be explained afterwards:
  - Compiled only under the `DEV_RECORDER` condition, which only the Debug configuration defines (AppCore's manifest and the App target); Release and Integration also leave the recorder's files out by name. `scripts/verify-release.sh` fails a bundle that contains the recorder's marker string or its string table, so its absence from a release is checked, not assumed.
  - Records what PLT-R905 records, plus: every engine decision with the token's display after it; every hard boundary with its reasons; every edit job (kind, strategy, outcome, events posted, durations) and every strategy fallback with its reason; VI/EN changes; a settings snapshot (values that change engine output; user word lists and macros only as counts) at the top of every file and on every change; focus snapshots with the compat rule and the decision (roles and bundle IDs, never window titles or URLs); and a field readback (at most 64 UTF-16 units before the caret, and the selection) at the first typing pause after a Backspace that edited, a committed word or a marker, at most one per 300 ms. A typing pause is 1 s without a key or click going down and without an edit job (twice the PLT-R382 bound of continuous typing): an observer cannot hold keys the way {{AppName}}'s jobs do (PLT-R311), and on the first evening a WebKit editor lost keys that went down a few tens of milliseconds before a readback taken 300 ms after a commit (amendment of 2026-11-14, ADR 0007 decision 10). Each readback records how long it waited, how long the input had been idle, how long its AX calls took (timeouts included) and the longest single call, and whether a key or click went down while it was in flight; the scanner does not compare such a read.
  - The recorder observes and changes nothing: apart from consuming its own marker chord it changes no verdict, job or setting, and the tap's side stays within PLT-R304 and PLT-R305. The readback runs off the tap with a short AX timeout through its own AX element reference (never the element the inject worker uses), only in a typing pause, never while an edit job is queued or in flight, never where the app's compat rule keeps the app off accessibility (`requireTextFocus: never`, as for Electron apps), never in a secure field or while secure input is on, and never sets `AXEnhancedUserInterface` or `AXManualAccessibility`.
  - Nothing is recorded while secure input is on, a secure field has focus or the recorder is paused; the gap is marked. A full ring writes a gap line instead of dropping records silently.
  - *(Amendment of 2026-11-15, ADR 0007 decisions 12 and 13.)* Every file and launch line carries an identity of the engine (a digest of the bundled engine's output for fixed probes, computed the same way by the app and by the scanner), and the scanner replays only segments written by its own engine build, counting the others in its summary. A focus snapshot that names no app records the application NSWorkspace calls frontmost, for attribution only (PLT-R381 keeps the system-wide AX focus authoritative). A secure gap line records the likely holder of secure input (bundle ID and process ID, PLT-R396) and its duration.
  - Stored in `~/Library/Logs/{{AppName}}/dev-traces/YYYYMMDD-HH.jsonl` (one file per local hour), folder 0700, files 0600, both excluded from backups. Deleted after 7 days; at most 200 MB in total, oldest first; purged at launch and hourly.
  - Always on from launch, without a confirmation. Visible for the whole time: a persistent dot on the menu bar icon, also named in its VoiceOver label; the status menu shows "recording" or "paused until HH:mm", pauses for 30 minutes or resumes, marks, and opens the folder.
  - Marker: Control+Option+Command+Semicolon in every app (consumed in development builds only) or the menu item; the icon flashes for about 1 second and VoiceOver announces it, without a window or a change of focus.
  - Never uploaded or sent anywhere. Nothing reads the files except the local scanner (`trace-scan`, `scripts/dev/trace-scan.sh`), whose summary shows metadata only; excerpts with typed content are read only around its findings. The scanner explains a readback that lacks exactly one passed key's character (naming the key only in the excerpt, with any readback that was in flight when it went down) or holds one character more, reports one divergence once, and flags slow readbacks (a timeout, or one AX call longer than the inject worker's 30 ms per call).
- **PLT-R905** Time-boxed capture for bug reports:
  - Started only by an explicit action in Diagnostics, with a confirmation that explains what is recorded.
  - Duration default 60 s, maximum 180 s, then it stops by itself.
  - Visible indicator for the whole duration: changed menu-bar icon plus a floating HUD with countdown and Stop button, on all Spaces and above full-screen apps.
  - Records layout characters, keycodes, flags, timings, engine decisions, jobs and focus snapshots (roles, bundle IDs; never titles or URLs). Nothing is recorded while secure input is on or a secure field is focused; the gap is marked.
  - Stored in `~/Library/Logs/{{AppName}}/captures/` (0600), excluded from backups (`isExcludedFromBackup`).
  - Deleted 24 hours after creation, or immediately after export or discard.
  - The user reviews a readable rendering before export. Never uploaded automatically.
- **PLT-R906** Network egress is limited to Sparkle: the appcast and update archives over HTTPS on `{{app-slug}}.kal.vn` only (the product owner chose this host for DMG and update archives on 13/11/2026; no GitHub Releases). No telemetry, analytics, crash-reporting SDKs, remote configuration, remote rules, remote fonts or web views loading remote content. Release notes are shown without loading remote resources.
- **PLT-R907** No translation feature in v1. If one is ever added: Apple's on-device Translation framework only, explicit per-use action, preview before replacing text. Rationale: the prior art's translation sent text to unofficial Google, Tencent and ByteDance endpoints while its README claimed fully local operation.
- **PLT-R908** Hardened runtime with no exceptions; no entitlements in v1; library validation on; no code loaded from outside the bundle. The app is not sandboxed because Accessibility clients and active keyboard taps are incompatible with App Sandbox.
- **PLT-R909** No unauthenticated IPC: no distributed notifications for control or settings, no listening sockets, no XPC listeners in v1, no AppleScript dictionary. A URL scheme `{{app-slug}}://` MAY open the Settings window only; it MUST NOT change settings, start capture, export data or trigger any action.
- **PLT-R910** Supply chain: `Package.resolved` committed; Sparkle pinned exactly; every tool CI downloads verified by SHA-256; GitHub Actions pinned by commit SHA; release workflows only on protected tags; no `pull_request_target`.
- **PLT-R911** Engine state is a value type that the host drops on reset; the host MUST NOT keep copies of engine state or raw keys beyond the current composition except inside the time-boxed capture (PLT-R905). Fixed-size buffers are forbidden (ENG-R640); secure wiping is best effort only because Swift strings cannot be zeroed reliably.
- **PLT-R912** Settings import treats files as untrusted: schema validation, 5 MB cap, no evaluation of any content.
- **PLT-R913** Per-app memory and overrides are user data; reports include only the entry for the reported app.

### Acceptance criteria (section 9)

- Canary test: automated typing of canary words (for example "zqxkanary") through every strategy; afterwards no file written by {{AppName}} outside `captures/`, and no unified-log output from the process, contains a canary.
- Egress test (section 13.7) shows only the allowed host.
- `codesign -d --entitlements` shows no entitlements; `codesign --verify --strict` and `spctl -a -vv` pass; hardened runtime flag present.
- The URL scheme with arbitrary parameters only opens Settings.

## 10. Settings storage, schema versioning, migrations

- **PLT-R1001** Location `~/Library/Application Support/{{AppName}}/` (folder rule from PLT-R903), directory 0700. Files, each 0600: `settings.json`, `app-modes.json`, `rule-overrides.json`, `macros.json`.
- **PLT-R1002** Each file is JSON with `schemaVersion` (integer) and `writtenBy` (app version). Unknown keys MUST be preserved on rewrite.
- **PLT-R1003** Writes are atomic (temporary file, fsync, rename), debounced by 1 s, serialized on the utility queue.
- **PLT-R1004** Only explicit user choices are persisted; defaults live in code and rules. Rationale: when a default is wrong and gets fixed, users who never touched it get the fix; prior-art support often answered bugs with "toggle setting X".
- **PLT-R1005** Migrations are pure functions from version N to N+1, chained. Before migrating, the original is copied to `backups/<file>.v<N>.<timestamp>.json` (keep the newest 5). CI holds a fixture for every released schema version and tests load, migrate and compare.
- **PLT-R1006** Never wipe: on a parse failure the file is renamed `.corrupt-<timestamp>`, the newest valid backup is loaded, else defaults are used in memory without overwriting anything until the user confirms; a notice explains what happened. Rationale: prior-art updates reset users' settings repeatedly.
- **PLT-R1007** A file written by a newer schema is used read-only (known fields), never rewritten, and a notice explains it.
- **PLT-R1008** Changes apply live via snapshot publication; no restart.
- **PLT-R1009** Crash-loop safe mode: three crashes within 60 s of launch start the app with defaults in memory, without touching files, and offer reset or report.
- **PLT-R1010** Export and import: one JSON file `{{app-slug}}-settings-YYYYMMDD.json` with `schemaVersion`, containing settings, rule overrides, per-app rules and modes, and macros (`03-product.md` PRD-R72). The export sheet lets the user untick macros and per-app modes, with a note that macros may contain private text. Import validates, shows a summary of changes, backs up current files, applies, and migrates older schemas; a newer schema is imported for the known fields and the skipped fields are listed.
- **PLT-R1011** iCloud sync (later, opt-in): `NSUbiquitousKeyValueStore` for settings, macros and overrides; never synced: capture state, logging, permission state, machine-specific paths; last writer wins per key with timestamps. Requires the key-value storage entitlement and a Developer ID provisioning profile (VERIFY).
- **PLT-R1012** All storage paths MUST be listed for the Homebrew cask `zap` stanza and for the uninstall help page.

### Acceptance criteria (section 10)

- Upgrading through every released version in sequence preserves every user choice (fixture test).
- Truncating `settings.json` to half its length leads to recovery from backup with a notice, no data loss beyond the last 1 s debounce window.
- Export on version N and import on version N+2 restores the same effective configuration.

## 11. Updates

- **PLT-R1101** Sparkle 2 (pinned) with `SUFeedURL = https://{{app-slug}}.kal.vn/appcast.xml`. Beta builds use `sparkle:channel="beta"` items in the same appcast; the app allows the beta channel only when the user opted in.
- **PLT-R1102** EdDSA (ed25519) signatures are mandatory (`SUPublicEDKey` in `Info.plist`); appcast and archives over HTTPS only. Sparkle's Apple code-signature continuity check stays enabled. SHOULD enable verification before extraction if the pinned Sparkle version supports it (VERIFY).
- **PLT-R1103** Key custody (the pipeline itself is owned by `04-quality-release.md`, QA-R31 and QA-R32; this requirement states the security floor). The EdDSA private key is generated on Pa's Mac, kept in the login keychain, with an offline encrypted backup in two places, and MUST NOT be stored in CI; EdDSA signing and appcast publication run on Pa's Mac through one scripted command. Developer ID signing and notarization run on Pa's Mac too (decision of the product owner, 13/11/2026); CI builds stay unsigned. If that ever changes, they MAY run in CI only inside a GitHub Environment `release` with Pa as required reviewer, secrets scoped to that environment, triggered only by tags on a protected branch, with a temporary keychain deleted at job end. Rationale: an update-signing key kept in CI secrets behind a manually triggered workflow turns one compromised account into a signed malicious auto-update for every user.
- **PLT-R1104** `CFBundleShortVersionString` is semver; `CFBundleVersion` is a monotonically increasing integer.
- **PLT-R1105** Automatic check every 24 h (user can disable), automatic download on. Installation happens when the user chooses "Relaunch to update" or at quit. The app MUST NOT relaunch itself automatically unless no key was pressed for 60 s and secure input is off. After relaunch, mode and per-app memory are as before.
- **PLT-R1106** Stable releases use phased rollout (`sparkle:phasedRolloutInterval`, for example 1 day per group). The critical-update flag is used only for security or data-loss fixes (QA-R34, PRD-R54).
- **PLT-R1107** Rollback: Sparkle does not downgrade. Procedure: (1) remove the bad item from the appcast immediately; (2) publish a new build from the last known-good source with a higher `CFBundleVersion`. Every published DMG stays downloadable from the archive page (QA-R38) and the signed update archives of the last 3 releases are kept for rebuilding. The rollback drill cadence is owned by QA-R39.
- **PLT-R1108** Every release candidate passes the update tests in section 13.5 before publication. Rationale: a prior-art auto-update left users unable to type until they reset settings and reinstalled.
- **PLT-R1109** Appcast items set `sparkle:minimumSystemVersion`; when a migration path is unsupported, `sparkle:minimumAutoupdateVersion` forces a manual install with an explanation.
- **PLT-R1110** Homebrew cask: `auto_updates true`, `depends_on macos: ">= :sequoia"`, `zap` paths per PLT-R1012.

## 12. Diagnostics

- **PLT-R1201** A Diagnostics window (from the menu) shows: health state with a plain explanation; permission states; secure input with likely holder; focused app and field (bundle ID, version, engine, role, subrole, identifier); matched rule, strategy, parameters and source; latency histograms; recent health events, with a label and a plain explanation for those that call for one (secure-input bursts, PLT-R397B); buttons "Copy report", "This app misbehaves...", "Record typing trace...", "Run typing latency test", "Open logs folder".
- **PLT-R1202** The environment report (plain text and JSON) contains: app version, build, channel; macOS version and build; architecture and model identifier; UI locale; keyboard layout ID and input-source type; permission states; tap state (enabled, location, timeouts in the last 24 h, last re-enable reason); secure-input state and likely holder bundle ID; focused app bundle ID, version, engine fingerprint, and whether the app came from the frontmost-app fallback (PLT-R381); focused field role, subrole, identifier, DOM classes, editable and secure flags; matched rule ID, specificity, strategy, parameters, override flag; non-content settings (input method, toggles); latency percentiles; last 50 health events; detected conflicting input apps.
- **PLT-R1203** The report MUST NOT contain: typed text, field values, window titles, URLs, clipboard data, macro bodies, the per-app memory list (except the reported app), file paths inside the user's home other than {{AppName}}'s own folders.
- **PLT-R1204** The user sees the exact report text before copying or exporting.
- **PLT-R1205** "This app misbehaves" flow:
  1. The user focuses the problem field and chooses the menu item.
  2. A panel shows the detected app, field, rule and strategy, and asks for the symptom (duplicated letters, missing letters, letters out of order, wrong tone position, nothing typed, lag, other).
  3. Optional guided test, only after the user confirms the focused field is empty and safe to type in: {{AppName}} types canary sequences with each candidate (current strategy; `backspaceReplace` with `axSelection`; with `placeholder`; `selectReplace`; `axReplace` for native apps; pacing 0, 2 and 5 ms). After each candidate it reads back via AX when possible, otherwise asks "Do you see 'đá â'? Yes / No", then removes the test text with the same strategy and reports any residue.
  4. It produces a rule suggestion in the section 5 schema: match from the snapshot (bundle ID plus role, subrole, identifier or DOM classes; a URL prefix only if the user ticks "include page address" and edits it down to a host-level prefix), action from the best passing candidate, provenance `{source: "user-suggestion", appVersion, macOS, date}`.
  5. Offers: "Use this for me now" (creates a user override), "Copy report", "Open GitHub issue" (prefilled with the redacted report, submitted by the user in the browser).
  6. Keyboard focus (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md): the panel takes keyboard focus while the user describes the symptom (step 2) and during the final offers (step 5), so Tab and Full Keyboard Access reach its controls (`03-product.md` PRD-R67), and it gives keyboard focus back to the problem field before each guided-test candidate (step 3).
- **PLT-R1206** Health events (metadata only): tap timeouts, watchdog trips, flushes, fallback activations, AX circuit-breaker trips, echo loss, permission transitions, secure-input episodes with holder bundle ID, rule-load errors, placeholder residue detections.
- **PLT-R1207** Support guidance (non-normative): ask for the report and, only if needed, a capture; never ask users for verbose logs. Rationale: prior-art users said they were "normal users" when asked for verbose debug logs, and 32 % of issues were reopened after being closed as fixed.

### Acceptance criteria (section 12)

- A report generated during a canary typing session contains no canary.
- The guided test on a local inline-completion test page recommends `axSelection` or `placeholder` and the resulting override fixes the symptom.
- A first-time user can produce a report in at most 3 clicks from the menu.

## 13. Acceptance tests

### 13.1 Hosted CI (no permissions)

- Pipeline property tests with fake poster, fake AX and fake clock: conservation (PLT-R312), ordering (PLT-R311), liveness ceiling (PLT-R314), generation discard (PLT-R316), keyUp pairing (PLT-R313), marker never on physical events (PLT-R321), fail-open transitions (PLT-R730). At least 100,000 random sequences per run.
- Engine fuzzing at the platform boundary: random key streams including Telex "quz" and VNI "qu0" style sequences and tokens longer than 64 keystrokes must never trap (ENG spec defines the corpus).
- Rules: schema validation, provenance and scenario presence, identical-signature detection, matcher unit tests, bundle-ID literal lint, forward-delete ban.
- Settings: migration fixtures, corruption recovery, unknown-key round trip, newer-schema read-only.
- Pasteboard preservation on a uniquely named pasteboard: multi-item, multi-type byte equality; marker types present; `changeCount` guard.
- Privacy canary over all written files and captured log output.
- Engine and pipeline microbenchmarks with gates (section 8.4).

### 13.2 Self-hosted integration runner

- A dedicated Mac (Apple silicon, macOS 27) plus a macOS 12 virtual machine on it (tart, ADR 0315) and a second Mac or VM with macOS 15 when available. Permissions are granted once to the stable-signed test build. VERIFY whether GitHub-hosted runners allow TCC grants; if they do, part of this suite may move there.
- `CompatHarness` keyboard driver posts physical-like events with timing profiles normal (80 to 150 ms), fast (30 ms) and burst (5 ms).
- Readback: AX for native apps; `safaridriver` and `chromedriver` for browser page fields; terminal capture (a shell writes stdin to a file) for terminals; human for the rest.
- Minimum automated scenario set: TextEdit, Notes, Safari address bar and page textarea, Chrome address bar with seeded history and page textarea, Firefox URL bar, Terminal (zsh), iTerm2, Ghostty, VS Code editor, Spotlight, a password field (asserts no transformation), Telex and VNI, ABC, QWERTZ, AZERTY and Dvorak layouts, Japanese input source (asserts pause), secure input (asserts pause and holder, then that the first key after release is composed: PLT-R398B), iTerm2 with secure keyboard entry turned on and off (asserts the holder hint names iTerm2: PLT-R398C), tap timeout injection (test hook), permission revocation during typing (asserts fail-open).
- Local test pages reproduce inline autocomplete, a first-keystroke edit-mode transition and a contenteditable composer, so completion strategies are tested deterministically without accounts.

### 13.3 Manual compatibility matrix

- `compat/matrix.json` in the repository (rendered to the website matrix and shown on the in-app Apps page, `03-product.md` PRD-R35 and PRD-R38, `04-quality-release.md` QA-R17): rows app x version x macOS; columns: Telex basic, VNI basic, inline completion, burst typing, backspace re-entry across ", ", restore hotkey, per-app memory, macro expansion, notes; cells pass, fail or n/a with date and tester. This file records verification status; `compat-rules.json` (section 5) records behaviour. They are separate files with separate schemas.
- Tier lists (which apps are release-blocking and which are checked per minor release) are owned by `03-product.md` PRD-R39; this file does not repeat them. Tier 1 rows must be at most 90 days old at release time on the latest macOS 26 and 27.

### 13.4 Latency and resource gates

Gates from section 8.1 enforced on every merge to the main branch (hosted subset) and nightly (self-hosted subset). A release candidate requires a green nightly within 24 hours.

### 13.5 Install and update tests

- Fresh install from the notarized DMG on macOS 12, 15, 26 and 27 (and on an Intel Mac with macOS 26 or earlier when available): Gatekeeper passes without warnings; the move offer appears when launched from the DMG.
- Update from the previous release through a local appcast: settings byte-identical apart from migrations; per-app memory intact; Accessibility trust intact; tap active within 2 s after relaunch; typing works without user action.
- Beta to stable channel switch and back.
- Rollback drill: pull an item, publish N+1 from N-1 source, confirm clients on N move to N+1.

### 13.6 Soak

8 hours of synthetic typing across three apps (TextEdit, Chrome page, Terminal) on the self-hosted runner: no crash, M2 within gate, zero flushes in the normal profile, zero watchdog trips.

### 13.7 Network egress

Run the app for 10 minutes with the feed pointed at a local appcast and a forced check, then with the production feed: connection monitoring (for example `nettop` sampling of the process or a local filtering proxy) shows only the allowed host.

### 13.8 Release gate summary

A release is publishable only if: hosted CI green; nightly self-hosted green within 24 hours; tier-1 matrix rows current; update tests green on three OS versions; no rule past `reviewBy` by more than 30 days; egress test green; signing, notarization and EdDSA verification checks green.

## 14. Open questions for Pa

All answered on 13/11/2026; every answer and where it is implemented is listed in `docs/decisions/0005-pa-decisions-2026-11-13.md` (the app licence in `docs/decisions/0006-app-licence-and-pro-edition.md`).

1. Minimum macOS: answered, macOS 12.0 with Intel support (universal binary kept); see `docs/decisions/0315-minimum-macos-12.md`.
2. App licence: GPL-3.0-or-later for everything outside the engine packages, the `data/` pipeline and the reference model, which are MPL-2.0 (ADR 0006, amended 15/11/2026); consequences for the rules database and the injection layer in PLT-R108.
3. Release signing: Developer ID signing and notarization happen on Pa's Mac (keys never leave it); CI keeps producing unsigned builds. The EdDSA key stays on Pa's Mac (PLT-R1103, QA-R32).
4. Archive hosting: DMG and update archives only on `{{app-slug}}.kal.vn` (no GitHub Releases, so PLT-R906 needs no extra host).
5. Self-hosted Mac runner: proposed as a tart macOS virtual machine on Pa's Mac (awaiting Pa's confirmation); Linux jobs stay on GitHub-hosted runners.
6. Accessibility enabling in Chromium or Electron apps: keep `axEnable: manual` (off unless a rule proves no side effect).
7. Zero-width placeholder: keep it behind the PLT-R422 gate. Until an automated 1,000-edit test exists, the Google Sheets and Excel rules use `axSelection` only and the matrix notes the imperfect behaviour.
8. Terminals: keep "inherit" (Vietnamese allowed in TUIs).
9. IMKit edition: decided after spike S1 (PLT-R398D).

## Appendix A. File locations

| Purpose | Path | Permissions |
|---|---|---|
| App | `/Applications/{{AppName}}.app` (or `~/Applications`) | as installed |
| Settings, overrides, per-app modes, macros | `~/Library/Application Support/{{AppName}}/` | dir 0700, files 0600 |
| Settings backups | `~/Library/Application Support/{{AppName}}/backups/` | 0700 / 0600 |
| Logs | `~/Library/Logs/{{AppName}}/` | 0700 / 0600 |
| Captures | `~/Library/Logs/{{AppName}}/captures/` | 0700 / 0600, excluded from backup, deleted after 24 h |
| Sparkle state | `~/Library/Preferences/vn.kal.{{app-slug}}.plist`, `~/Library/Caches/vn.kal.{{app-slug}}/` | system defaults |

## Appendix B. Glossary

- **Composition**: the current word the engine is building, plus limited history of previous words for re-entry.
- **Edit job**: a unit of injection (delete count plus insertion) executed atomically with respect to other keyboard events.
- **Held event**: a physical keyboard event swallowed by the tap because a job is in flight, later replayed.
- **Echo**: a synthetic event observed coming back through {{AppName}}'s own tap.
- **Snapshot**: an immutable value published by one thread and read by others with a single atomic load.
- **Rule**: a JSON entry that maps a focused context to a strategy and parameters.
- **Strategy**: a generic injection method (section 4).
- **Engine fingerprint**: classification of an app's UI technology derived from its bundle contents.
- **Fail-open**: a state in which {{AppName}} lets every key through untouched because it cannot guarantee correct behaviour.
