// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dedicated threads (PLT-R203). Swift concurrency cannot express "this state belongs to the ax run-loop
// thread", so confinement is enforced by construction plus debug assertions, in exactly two audited types.

public import Foundation

/// State owned by exactly one dedicated thread (tap, inject or ax). The first `withValue` call binds the
/// owner; later calls from another thread trap in debug builds.
public final class ThreadConfined<Value>: @unchecked Sendable {
    private var value: Value
    private let owner = Atomic<UInt>(0)

    public init(_ value: Value) { self.value = value }

    @inline(__always)
    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        #if DEBUG
        let current = UInt(bitPattern: pthread_self())
        let (exchanged, original) = owner.compareExchange(
            expected: 0, desired: current, ordering: .relaxed)
        assert(exchanged || original == current, "ThreadConfined accessed from a second thread")
        #endif
        return try body(&value)
    }
}

/// A `Thread` with its own CFRunLoop that stays alive until `stop()`. Used for the `ax` thread (AXObserver
/// sources). The `tap` thread does NOT use this type because its run loop must contain only the tap source
/// (PLT-R303); see InputHost `TapThread`.
public final class RunLoopThread: Sendable {
    private struct State: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var thread: Thread?
        var threadID: UInt = 0
    }

    public let name: String
    public let qualityOfService: QualityOfService
    private let state = Mutex(State())
    private let ready = DispatchSemaphore(value: 0)

    public init(name: String, qualityOfService: QualityOfService) {
        self.name = name
        self.qualityOfService = qualityOfService
    }

    /// Starts the thread and returns once its run loop is ready. Calling it again while the thread runs does
    /// nothing, so a second thread can never share this object's state.
    public func start() {
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)
            state.withLock {
                $0.runLoop = runLoop
                $0.threadID = UInt(bitPattern: pthread_self())
            }
            ready.signal()
            CFRunLoopRun()
            // Stopped: later `perform` and `addSource` calls become no-ops instead of targeting a dead loop.
            state.withLock { $0 = State() }
        }
        thread.name = name
        thread.qualityOfService = qualityOfService
        let alreadyStarted = state.withLock { state in
            guard state.thread == nil else { return true }
            state.thread = thread
            return false
        }
        guard !alreadyStarted else { return }
        thread.start()
        ready.wait()
    }

    /// Runs `block` on this thread's run loop (CFRunLoopPerformBlock + wake-up). Not for the tap thread.
    public func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Adds a run-loop source (for example `AXObserverGetRunLoopSource`) from any thread.
    public func addSource(_ source: CFRunLoopSource) {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
    }

    public func removeSource(_ source: CFRunLoopSource) {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }

    public var isCurrentThread: Bool {
        state.withLock { $0.threadID } == UInt(bitPattern: pthread_self())
    }

    public func stop() {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopStop(runLoop)
    }
}
