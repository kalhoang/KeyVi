# 0311. "In flight" ends at the echo, not at the post

- Status: accepted, 2026-11-13 (revises the hold rule of ARCHITECTURE.md section 4 and contracts.md 9);
  amended 2026-11-13 after wave 1: recovery from posting broken (see the amendment at the end)
- Requirements: PLT-R311, PLT-R312, PLT-R314, PLT-R323, PLT-R330, PLT-R331, PLT-R332, PLT-R730,
  PLT-R301 VERIFY (a)
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

   **Forgiven echoes (final review, 2026-11-13).** Events posted while the tap is disabled bypass it and never
   echo. Expectations posted before a tap re-enable (a tap-disabled event, or the watchdog's recovery after a
   trip) are therefore forgiven through `EchoTracker.forgiveLostEchoes(postedAtOrBefore:)`, called on the
   tap-disabled event (`KeyPipeline+Flow.swift`) and around every re-enable (`TapSession.reenable`, which also
   covers the watchdog window). A forgiven expectation still keeps its job in flight until the 200 ms timeout,
   so holding is unchanged, but its timeout does not count toward the three-miss `postingBroken` rule
   (PLT-R330, PLT-R306, PLT-R323). Without this, one watchdog trip while typing fast turned three lost echoes
   into a `postingBroken` outage of at least 30 s.
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

## Amendment 2026-11-13: recovery from posting broken (wave 1)

Context: the first version of `HostLifecycle` recreated the tap only on a permission transition from not
granted to granted. Echo loss and OS policy (PLT-R323) can break posting while every permission still reads
`ready`, so the permission monitor never reports a change and a host in `failOpen(postingBroken)` would stay
fail-open until the user relaunched the app.

Decision:

1. `.postingBroken` performs the PLT-R730 teardown in order (publish `failOpen(postingBroken)`, flush, reset the
   composition, remove the tap), then records `.recordHealth(.postingBroken)` and returns
   `.scheduleRetry(after: delay)`.
2. `.retryTimerFired` in that phase returns `[.createTap]` while the phase stays `failOpen(postingBroken)`, so
   the menu does not flicker during the attempt. Success moves to `running`; a failed creation moves to
   `failOpen(tapUnavailable)` with the PLT-R332 backoff (1, 2, 5, 10 s). A permission loss moves to
   `failOpen(permissionRevoked)` and cancels the retry; permission back then recreates the tap (PLT-R731).
3. The delay is `HostLifecycle.postingBrokenBackoff`: 30 s, doubling (60 s, 120 s, 240 s) to a cap of 300 s
   (5 minutes). A new break within the previous delay plus `HostLifecycle.postingBrokenStableInterval` (600 s)
   of the previous break moves one step up; otherwise the backoff restarts at 30 s. In words: retry with a 30 s
   backoff doubling to a 5-minute cap, restarted after 10 minutes of stable posting. A posting path that stays
   broken therefore costs at most one tap creation every 5 minutes, never a create-and-break loop.
4. `HostLifecycle.disableCoalescingWindow` (1 s) belongs to the same review: the OS disable event and the
   watchdog's `CGEventTapIsEnabled` check can both report one disable. Each report still runs the re-enable
   procedure (PLT-R330), but reports closer than 1 s count once toward the instability notice (PLT-R331).

The constants are public on `HostLifecycle` (`Packages/AppCore/Sources/InputHost/Lifecycle/HostLifecycle.swift`)
and pinned by `Tests/InputHostTests/Lifecycle/HostLifecycleRecoveryTests.swift`; contracts.md 10.3 describes
the same behaviour.
