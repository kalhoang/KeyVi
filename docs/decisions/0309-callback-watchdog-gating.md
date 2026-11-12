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
  `watchdog` health event, enters `failOpen(watchdog)` and retries after 2 s.

## Consequences

- Worst-case detection latency while typing is about 275 ms; the OS's own tap timeout remains a backstop.
