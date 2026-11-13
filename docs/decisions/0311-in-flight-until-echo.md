# 0311. "In flight" ends at the echo, not at the post

- Status: accepted, 2026-11-13 (revises the hold rule of ARCHITECTURE.md section 4 and contracts.md 9)
- Requirements: PLT-R311, PLT-R312, PLT-R314, PLT-R323, PLT-R730, PLT-R301 VERIFY (a)
- Context: PLT-R311 says that while `inFlight > 0` ("jobs pushed but final event not yet posted") every
  keyboard event the pipeline would pass is held. Its rationale: "a later physical key must never reach the app
  between the backspaces and the insertion of an earlier edit; users reported garbled words when typing fast".
  `CGEventPost` only appends to the WindowServer's queue. A physical key that reached the WindowServer before
  the worker posted (the tap thread was preempted or still inside the previous callback) is ahead of the
  synthetic events in that queue. If "in flight" ends when `CGEventPost` returns, that key reaches the tap
  after `inFlight` dropped to 0, is passed, and reaches the app before the synthetic backspaces and insertion:
  exactly the garbled-word bug the requirement exists to prevent. A property test with a fake poster cannot see
  this, because the fake has no server queue. (Independent design review, finding 1.)

## Decision

1. **Definition.** A job is in flight from `JobQueue.push` until one of:
   - the tap sees the echo of the job's final posted event (PLT-R323 already tags every synthetic event with a
     23-bit sequence in `kCGEventSourceUserData`);
   - 200 ms (the PLT-R323 echo timeout) pass after the final event was posted without that echo; this counts
     as one echo miss;
   - the worker reports that the job posted nothing (`BoundaryJob`, a dropped `pairedKeyUp`, an empty edit).
   Echoes travel through the same WindowServer queue as physical events, so every physical key that was queued
   before the job's events reaches the tap before the echo and is held. Ordering follows from the queue order.
2. **Single writers.** `JobQueue` keeps three monotonic counters: `pushed` (tap), `settledByTap` (tap: echo or
   timeout) and `settledByWorker` (worker: nothing posted). `inFlight = pushed - settledByTap -
   settledByWorker`, two atomic loads on the tap. The worker publishes an `EchoExpectation` (job, final event
   sequence, posted time) through an SPSC ring inside `JobQueue`; the tap-confined `EchoTracker` drains it at
   callback entry, keeps a fixed-capacity pending list, settles on echo (a watermark covers echoes that
   overtake their expectation) and settles expired entries lazily at the next callback. No timer runs on the
   tap and nothing allocates.
3. **Echo loss moves to the tap.** Three consecutive misses make `EchoTracker.settle` return `.postingBroken`;
   the pipeline fails open in the same callback (PLT-R730), marks `WorkerFeedback.postingBroken` and sends
   `MainNotice.postingBroken`. The first miss of a run sends `MainNotice.echoMissed`, on which the utility queue
   checks `CGPreflightPostEventAccess()` (false also means posting broken); the poster never preflights per
   post.
4. **Fallback.** If PLT-R301 VERIFY (a) shows that the app's own session tap does not receive its posted
   events, `JobQueue(policy: .untilPosted)` restores the literal reading (in flight until posted) and PLT-R323
   is removed as the spec instructs ("fall back to permission polling only"). The policy is a constructor
   argument, so the switch is one line in the composition root plus an ADR.
5. **Test model.** `SimulatedWindowServer` (TestSupport) models the server FIFO: physical and posted events share
   one queue in front of the tap, and in `.lagging` mode physical events wait until a `.tapDrains` step. The
   13.1 property suite runs both modes; with `.untilPosted` the lagging mode must find ordering violations
   (a self-check that the model can see the bug).

## Why the rationale and not the letter

The letter ("final event not yet posted") names a proxy that is observable in the worker; the requirement's
purpose is an ordering guarantee at the app. Only the echo shows that the WindowServer has dispatched the
synthetic events past every earlier physical event. Holding a little longer (until the echo, normally well
under a millisecond, at most 200 ms when echoes are lost) costs nothing visible and keeps PLT-R314's liveness
ceiling as the upper bound.

## Consequences

- When posting breaks silently (permission revoked: `CGEventPost` reports nothing), held events and triggers
  inside the detection window cannot be delivered (replay is also a post). Conservation (PLT-R312) is therefore
  guaranteed only while posting works; losses after posting broke are counted in
  `PlatformMetrics.lostWhilePostingBroken` and one `postingBroken` health event with `.count(n)`
  ([0308](0308-conservation-on-abandoned-edits.md)). This matches PLT-R314's "a garbled word is acceptable, a
  stalled keyboard is not".
- `PostError.notPermitted` is removed: the poster cannot observe it. `FakeEventPoster` gained
  `.silentlyDropping`, which models the real failure.
