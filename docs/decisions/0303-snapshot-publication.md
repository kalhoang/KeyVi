# 0303. Snapshot publication and cross-thread signalling on the hot path

- Status: accepted, 2026-11-13
- Requirements: PLT-R203, PLT-R304, PLT-R305, PLT-R382, PLT-R388, PLT-R391, PLT-R803
- Context: The tap callback reads settings, focus, input-source, secure-input and lifecycle state on every
  event. PLT-R388 demands an immutable value published through one atomic reference and read with a single
  atomic load. PLT-R305 forbids locks another thread can hold for unbounded time, allocation in steady state,
  `DispatchQueue.sync`, async/await and messaging AppKit. Swift 6's `Synchronization` module (macOS 15)
  provides `Atomic` and `Mutex` but no atomic strong reference: `Atomic<Unmanaged<T>>` is available, and the
  hard part is reclaiming the old object without a use-after-free.

## Decision

### Snapshot cell (RealtimeSupport `SnapshotCell<Value>`)

- Storage: `Atomic<Unmanaged<Box>>` where `Box` is a final class holding the immutable `Value`; the cell owns
  one +1 retain on the current box.
- Tap read: `current.load(ordering: .sequentiallyConsistent)._withUnsafeGuaranteedRef { body($0.value) }`.
  One atomic load, no retain, no lock, no allocation. The value is borrowed for the closure only.
- Reclamation is quiescent-state based (QSBR) with exactly one fast reader, the tap thread. A shared
  `ReaderEpoch` counter is incremented at callback entry and exit (odd = inside). `publish` (main, ax or
  utility thread) exchanges the pointer, records the epoch it observes right after the exchange, and frees a
  retired box when that epoch was even (the tap was outside a callback, so every later callback loads the new
  box) or when the counter has moved on since (the callback that might hold the box has ended). Both the
  exchange and the epoch operations are sequentially consistent, which gives the Dekker-style ordering this
  argument needs. Boxes are therefore always released on a writer thread, never on the tap.
- Retired boxes are reclaimed on the next publish and by the utility watchdog; the list stays bounded because
  the tap never stays inside a callback for long (PLT-R306 trips at 250 ms).
- Other readers (main, ax, utility) call `load()`, which takes the writer-side `Mutex` for O(1) work and
  returns a strong copy. The inject worker never reads snapshot cells: everything it needs travels inside the
  job, plus the `CurrentFocusGeneration` atomic.
- Why it never blocks the tap: the tap path contains two atomic increments and one atomic load per cell; no
  operation on it can wait for another thread, and no deallocation can happen on it.

### Cross-thread signalling

| From -> to | Payload | Wake-up |
|---|---|---|
| tap -> inject | `SPSCRing<InjectionJob>` inside `JobQueue` | `DispatchSemaphore.signal()` (never blocks the caller; only the worker waits, with absolute deadlines) |
| tap -> main | `SPSCRing<MainNotice>` | `WakeSignal`: a `DispatchSourceUserDataAdd` merge targeting the main queue (lock-free, allocation-free, coalescing) |
| tap -> ax | `SPSCRing<AXNotice>` | `WakeSignal` targeting a utility queue whose handler hops to the ax run loop with `CFRunLoopPerformBlock` + `CFRunLoopWakeUp` |
| tap -> utility | `TapLogRing`, capture ring, watchdog activity | `WakeSignal` |
| inject -> tap | `WorkerFeedback` atomics (reset requests, job outcomes, posting broken) | none: the tap reads them at the next callback |
| ax -> inject | `CurrentFocusGeneration` atomic | none |

## Alternatives considered

- `Mutex<Value>` read on the tap: the uncontended path is lock-free, but a writer preempted while holding the
  lock makes the tap wait; PLT-R305 forbids exactly that.
- `Atomic<Unmanaged>` with "keep the last N boxes alive": unsafe under bursts of focus notifications.
- Split reference counts with a double-width CAS (`WordPair`): correct for many readers but far more complex
  than needed for one reader.
- Seqlocks over value storage: impossible with ARC-managed fields.
- `DispatchQueue.main.async` from the tap: allocates a block per call.

## Verification

`RealtimeSupportTests` exercise publication under a concurrent writer and the SPSC ring across threads; both
pass under Thread Sanitizer (2026-11-13). Workstream W1-A adds stress tests and benchmarks.
