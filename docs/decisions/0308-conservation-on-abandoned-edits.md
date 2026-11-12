# 0308. Event conservation when an edit job is abandoned

- Status: accepted, 2026-11-13
- Requirements: PLT-R311-R316, PLT-R313, PLT-R330, PLT-R730
- Context: PLT-R312 says every physical keyboard event has exactly one outcome: passed, replayed once,
  consumed as an engine trigger whose effect an `EditJob` delivers, or consumed as a hotkey. PLT-R314 (liveness
  flush) and PLT-R316 (generation discard) abandon edit jobs that have not started. Taken literally, the
  trigger key of an abandoned job would then have no delivered effect: a lost keystroke.

## Decision

- Every `EditJob` whose trigger key is not otherwise queued carries the trigger as a `KeyEventRecord`. When
  the worker abandons or discards the job, it replays the trigger instead (marked, in FIFO position). The user
  sees the plain letter: "a garbled word is acceptable, a stalled keyboard is not" (PLT-R314), and no key is
  lost.
- For `thenPassThrough` edits the original key is already queued as a `ReplayJob`, so the job carries no
  trigger (no double delivery).
- The keyUp of a consumed keyDown (PLT-R313) is resolved without races: the tap keeps a fixed-size table of
  consumed keyDowns (keycode -> job sequence). On the keyUp it reads the job outcome from `WorkerFeedback`
  (64-entry board, one atomic load): executed -> consume the keyUp; abandoned -> treat the keyUp as a normal
  pass/hold (its keyDown was replayed); still queued -> push `pairedKeyUp(record, forJob:)`, which the worker
  drops if the job executed and replays if it was abandoned.
- After a flush or discard the worker increments the composition-reset counter; the tap resets the engine at
  the start of its next callback (`ResetReason.unknown` for flushes).

## Consequences

- The conservation ledger in TestSupport checks this exact rule set; the property suite (13.1) covers flush
  and discard paths with 100,000 random sequences.
