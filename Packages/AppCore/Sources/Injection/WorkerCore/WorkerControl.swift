// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Any-thread control surface of the worker: the `inject` thread, its stop flag and the asynchronous flush
// request (PLT-R203, PLT-R314). Nothing here blocks the tap: `requestFlush` is one atomic store plus a signal.

internal import Foundation
internal import RealtimeSupport

final class WorkerControl: Sendable {
    /// Bounded wait in `stop()` for the loop to exit (shutdown only, never on a hot path).
    static let stopTimeout: TimeSpan = .seconds(1)
    static let threadName = "inject"

    let signal: WorkerSignal
    private let stopRequested = Atomic<Bool>(false)
    private let running = Atomic<Bool>(false)
    /// 0 = none, otherwise `FlushReason.rawValue + 1`.
    private let flushRequest = Atomic<UInt8>(0)
    private let exited = DispatchSemaphore(value: 0)

    init(signal: WorkerSignal) { self.signal = signal }

    var isStopRequested: Bool { stopRequested.load(ordering: .acquiring) }
    var isRunning: Bool { running.load(ordering: .acquiring) }

    /// Starts the dedicated thread once; a second call while running does nothing.
    func start(_ body: @escaping @Sendable () -> Void) {
        guard running.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        stopRequested.store(false, ordering: .releasing)
        let thread = Thread { [self] in
            body()
            running.store(false, ordering: .releasing)
            exited.signal()
        }
        thread.name = Self.threadName
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Asks the loop to exit and waits a bounded time for it.
    func stop() {
        guard isRunning else { return }
        stopRequested.store(true, ordering: .releasing)
        signal.signal()
        let nanoseconds = InjectionTiming.nanoseconds(Self.stopTimeout)
        _ = exited.wait(timeout: .now() + .nanoseconds(Int(nanoseconds)))
    }

    func requestFlush(_ reason: FlushReason) {
        flushRequest.store(reason.rawValue &+ 1, ordering: .releasing)
        signal.signal()
    }

    func takeFlushRequest() -> FlushReason? {
        let value = flushRequest.exchange(0, ordering: .acquiringAndReleasing)
        return value == 0 ? nil : FlushReason(rawValue: value &- 1)
    }
}
