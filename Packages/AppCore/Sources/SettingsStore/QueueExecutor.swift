// SPDX-License-Identifier: GPL-3.0-or-later
//
// Serial executor that runs an actor's jobs on one dispatch queue (PLT-R203 "utility queue"), for macOS 12 and
// later (docs/decisions/0315-minimum-macos-12.md). `DispatchSerialQueue` only acts as an executor from macOS 14,
// and `assumeIsolated` from a plain dispatch block only works from macOS 15 (`checkIsolated`), so the store uses
// this executor on every system and `withQueueIsolation` instead of `assumeIsolated`: one code path everywhere.

internal import Dispatch

final class QueueExecutor: SerialExecutor {
    /// Serial queue every job runs on.
    let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    // `enqueue(_: UnownedJob)` is the requirement every system since macOS 10.15 calls; the `ExecutorJob`
    // variant needs macOS 14.
    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}
