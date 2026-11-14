# 0322. The keyUp of a passed keyDown is never held

- Status: accepted, 2026-11-15 (amends PLT-R311 and the hold rule of [0311](0311-in-flight-until-echo.md))
- Requirements: PLT-R311, PLT-R312, PLT-R313, PLT-R320, PLT-R324, PLT-R304
- Context: PLT-R311 holds every event the pipeline would pass while a job is in flight, keyUps included, and the
  worker replays a held event as a new event built from its record (`CGEventFactory.makeReplay`: a private-state
  source, a new timestamp, the app's own marker in `kCGEventSourceUserData`, posted at the session tap). The
  product owner's dev traces of 14 and 15/11/2026 in a messenger built on WKWebView (a Tauri app) showed what this
  does to a fast typist. A key K goes down and the tap passes it; the tone key goes down one or two milliseconds
  later and starts an edit; K's keyUp arrives while that edit is in flight (until its echo, ADR 0311), so the tap
  holds it and the worker replays a rebuilt keyUp. The app therefore receives the keyboard's keyDown of K but the
  worker's keyUp of K, and the next physical press of K never reaches the field, although the tap passed it. All 5
  such keys a readback could check were lost (first letters of "cái", "coi", "Xkey", "mục", "nhận"), against 0 of
  89 checkable rollovers whose keyUp had passed (Fisher's exact test, p about 2e-8); 2 more such keys show up only as
  the product owner's corrections. Which layer inside the app keeps K "down" is not known (WebKit's input-method
  path and AppKit's press-and-hold are candidates); a terminal showed no loss after 19 such keys.

## Decision

1. **A keyUp follows how its keyDown left the tap.** `ConsumedKeyTable` (keyed by key code, one fixed allocation)
   records the outcome of the last keyDown of each key, autorepeat included: `passedDown` when the keyDown passed
   unchanged (`passOrHold` with nothing in flight, a full queue, fail-open), `heldDown` when it was queued as a
   replay, and, as before, the consumed states (`job`, `withoutJob`, `hotkey`, PLT-R313, ADR 0308). The keyUp of a
   `passedDown` key passes at once with outcome `passed`, even while jobs are in flight. A `heldDown` keyUp, or one
   with no recorded keyDown, keeps today's rule, so a keyUp still follows its own replayed keyDown. `handleKeyDown`
   clears the entry before the new keyDown's outcome sets it, so a held autorepeat after a passed press holds its
   keyUp again.
2. **Why this keeps PLT-R311's purpose.** The rule exists so that no physical key lands between the backspaces and
   the insertion of an edit. A keyUp inserts nothing, so passing it early cannot garble a word. It reaches the app
   earlier than the held events and edits around it; apps that track key state see the key released a few
   milliseconds before the edit instead of after it, which is the order a slightly faster finger would give.
3. **Modifier releases stay held.** A `flagsChanged` event that releases a modifier whose press passed was
   considered (synthetic events carry explicit flags, PLT-R320, so the edit's own events are not affected). It is
   not exempt: a held key typed with that modifier is replayed with its recorded flags, but an app that tracks
   modifier state from `flagsChanged` (games, remote-desktop clients, JVM apps) would see the modifier go up before
   that key arrives and could read it without the modifier. No held `flagsChanged` appears in the traces, so there
   is no evidence that would justify the risk.
4. **Conservation.** PLT-R312 is unchanged: such a keyUp has one outcome, passed. `TestSupport`'s
   `ConservationLedger` excludes the keyUp of a passed keyDown from the cross-key order but checks that it reaches
   the field after its own keyDown, and reports a new violation, "replayed keyUp of a passed keyDown". The ledger
   pairs a keyUp with the last keyDown of its key that no earlier keyUp paired with, as the pipeline does.

## Verification

- `KeyPipelineRolloverTests` (Swift Testing): the keyUp of a passed key passes while an edit is in flight and no
  replay is queued; the keyUp of a held keyDown and of a held autorepeat stays held; keyDowns passed on a full
  queue or while failing open; the PLT-R313 pairing of consumed keys; a modifier release stays held.
- `ConservationLedgerTests` and the 13.1 property suites (`PipelinePropertyTests`, the combined suite with the real
  worker) at 100,000 sequences per window-server mode with the amended ledger.
- `PipelineAllocationTests.rolloverAndUnseenKeyUpsAllocateNothing`: the new paths allocate nothing (PLT-R304).
- TestHost scenario `TestHost/Scenarios/rollover-keyup.json` (`testhost.web.rolloverKeyUp`) for a run inside a test VM (runbook
  `docs/runbooks/integration-suite.md` section 10.8): hardware-like events into TestHost's web textarea and
  contenteditable and an `NSTextView` control, with a release 0.3 ms after the tone key; expected "dù mục " in 50 of
  50 trials. Not yet run; the scenario schema has no raw-event step, so the runbook gives the manual procedure.

## Consequences

- A rebuilt keyUp after a physical keyDown no longer happens for passed keys. It can still happen after a consumed
  keyDown whose job was abandoned (its keyDown is replayed too, so both halves are rebuilt) and after a held
  autorepeat (the repeat is rebuilt, the press was physical); neither appeared in the traces.
- The dev recorder's `held` keyUp pattern (a held keyUp K followed by a lost press of K) stays the scanner's hint for
  traces written before this change (`docs/runbooks/dev-recorder.md`).
