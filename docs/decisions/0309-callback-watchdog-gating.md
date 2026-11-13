# 0309. Callback watchdog without steady-state timers

- Status: accepted, 2026-11-13
- Requirements: PLT-R306, PLT-R331, PLT-R803, C1 (idle CPU)
- Context: PLT-R306 asks a utility-queue watchdog to disable the tap if one callback runs longer than 250 ms;
  PLT-R803 forbids steady-state timers faster than every 2 s. A plain 250 ms timer would violate PLT-R803 and
  C1 while idle.

## Decision

- The tap writes the callback entry time into an atomic at entry and clears it at exit (`CallbackWatchdog`).
- The 250 ms check runs as a repeating `DispatchSourceTimer` (10 % leeway) only while keys are flowing: the
  first callback after 2 s of inactivity signals the watchdog through a `WakeSignal` (allocation-free), which
  arms the timer; the timer disarms itself after 2 s without callbacks. Idle wakeups stay at zero.
- Separately, the tap-enabled check (`CGEventTapIsEnabled`, PLT-R331) runs every 5 s with leeway and on wake,
  session activation and permission change.
- A trip disables the tap with `CGEventTapEnable(false)` from the utility queue (keys flow), records a
  `watchdog` health event and enters `failOpen(watchdog)`. Nothing else touches the tap thread: it may be stuck
  inside the callback (an engine loop, a bug), and a stuck thread can neither re-enable nor stop its tap.
- Recovery (amended 2026-11-13, design review finding 7): 2 s after the trip the watchdog checks
  `CallbackWatchdog.isInsideCallback`. If the callback has returned, the lifecycle re-enables the same tap (or
  stops and recreates it on a fresh `TapThread` only after the old thread's run loop exited, `TapControl.isRunning
  == false`). If it has not returned, the host stays in `failOpen(callbackStuck)`: no second tap and no second
  tap thread, because a new reader on the same `ReaderEpoch` and snapshot cells would break the single-reader
  reclamation argument of [0303](0303-snapshot-publication.md) and PLT-R302. The status line says the app needs to
  be reopened (`StatusLine.Action.reopenApp`); keys keep flowing because the tap is disabled.
- `TapWatchdog` also calls `TapSnapshots.reclaimAll()` on its 5 s tick, so retired snapshot boxes are freed even
  when no writer publishes.

## Consequences

- Worst-case detection latency while typing is about 275 ms; the OS's own tap timeout remains a backstop.
