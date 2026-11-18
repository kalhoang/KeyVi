# 0306. How the engine is bridged into the input host

- Status: accepted, 2026-11-13
- Requirements: PLT-R307, PLT-R310 (steps 7-9), PLT-R911, ENG-R850, ENG-R1107, ENG-R1210, ENG-R1211,
  ENG-R1230, ENG-R1231
- Context: The engine (`Packages/VietnameseEngine`, public API fixed in `PublicAPI.swift`) is a pure value
  type: `Engine.reduce(state, event) -> (state, output)` and a `Session` wrapper. Configuration changes mean a
  new `Engine` plus `reset(.configurationChanged)`. Per-app behaviour changes the engine's `appContext`,
  `autoRestore` and macro table (`features`, `engineContext`). The tap must not allocate or load resources.

## Decision

1. **Prebuilt catalog.** On every settings change the utility queue builds an `EngineCatalog` of eight
   `Engine` values, one per `EngineVariant` (appContext general/code x englishRestore on/off x macros on/off),
   and publishes it inside `TapSettingsSnapshot`. Bundled lexicons are loaded once with
   `Resources.bundled(userKeepRaw:userKeepVietnamese:macros:)` (ENG-R1231, at most 50 ms) and shared by value
   (copy-on-write sets); variants differ only in configuration and in `Resources.macros` (empty when macros
   are off, ENG-R1107).
2. **One session on the tap thread.** The pipeline keeps one `CompositionEngine` (production:
   `VietnameseCompositionEngine` wrapping `Session`) in tap-thread-confined state. It swaps the engine only at
   a hard boundary: focus change (new variant from the focus snapshot), settings generation change, or a reset
   request from the worker. Swapping is a struct copy of a prebuilt `Engine` and `Session(engine:)` with
   `.initial` state, followed by no edits (ENG-R1011, ENG-R1211).
3. **Event mapping (PLT-R307).** Layout-translated characters become `.key(KeyInput(ch, fromKeypad:))`; user
   backspace `.backspace` (autorepeat backspaces one by one, PLT-R351); the restore hotkey `.restoreToggle`;
   hard boundaries `.reset(reason)` with the matching `ResetReason` (`pointerClicked`, `focusChanged`,
   `applicationChanged`, `cursorMoved`, `shortcut`, `forwardDelete`, `inputSourceChanged`,
   `secureInputChanged`, `eventTapReenabled`, `modeToggled`, `configurationChanged`, `unseenInput` for a keyUp the
   tap never saw go down (PLT-R397A), `unknown` for flushes).
   Return and Tab are fed as `.key("\n")` / `.key("\t")` first (commit and restore, ENG-R912, P0-3) and then
   treated as hard boundaries by the host.
4. **Output mapping.** `.passThrough` -> pass (or hold while busy); `.edit(e, thenPassThrough: false)` ->
   `EditJob` (key consumed, its keyUp consumed); `.edit(e, thenPassThrough: true)` -> `EditJob` followed by a
   `ReplayJob` of the original key, so punctuation and Return reach the app after the correction (P0-3). An
   edit with `deleteCount == 0` and empty insert swallows the key without a job. `EngineOutput.learning` goes
   to the main outbox (ENG-R861); `decision` codes go to the capture only.
5. **Testability.** The pipeline is generic over `CompositionEngineFactory`; property tests use
   `ScriptedEngine` (TestSupport) so the conservation and ordering suites do not depend on engine progress.
6. **Privacy.** The host keeps no copy of engine state or raw keys beyond the session (PLT-R911); learning
   signals are held in memory only until the user accepts them into a list.

## Amendment of 19/11/2026: continuing the word across a `lookaheadRevision` change

The first full TestHost run in the VM since 13/11 failed `testhost.panel.inlineCompletionTwice` with `vieejt` once:
the search panel's field, whose rule turns `lookaheadRevision` off, was published after the first key, and the
variant change ended the word even though the late focus change of PLT-R340 would have kept it. Decision 2 now has
one exception (ENG-R1211 amendment of the same day): when a kept late focus change moves to a variant that differs
only in `lookaheadRevision`, the engine has committed nothing since its last reset and no learned-memory swap waits,
the pipeline asks the factory for the new variant's prebuilt engine continuing the current state
(`CompositionEngineFactory.makeEngine(for:settings:continuing:)`, production `Session(engine:state:)`), with no
reset and no edit. Such a state is the active word alone, which the switch does not affect
(`LookaheadRevisionContinuationTests`). Any other variant change, or this one after a commit, still swaps in a
fresh engine at the hard boundary.

## Open issue for the engine track

D10 ("expand macros in English mode", default off) needs macro matching without Vietnamese composition. The
12.2 API has no configuration for that. Proposal: an `EngineConfiguration` flag (for example
`compose: Bool = true`) or an `InputMethod.literal` case. Until the engine offers it, the host does not feed
the engine in EN mode (PLT-R310 step 6) and the D10 toggle stays hidden; the default behaviour (off) is
already correct.
