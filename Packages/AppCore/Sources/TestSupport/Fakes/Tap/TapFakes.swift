// SPDX-License-Identifier: GPL-3.0-or-later
//
// Event tap fakes (ADR 0313): never create a real tap and never talk to the WindowServer. Implemented in the
// skeleton; workstream W1-F2 owns this directory and may add behaviours.

public import CoreFoundation
public import CoreGraphics
public import InputHost
internal import RealtimeSupport

/// Pure Swift tap handle. `install` adds a run-loop source that does nothing unless a test schedules a block
/// with `performOnTapThread` (so the tap thread's run loop has a source and keeps running), and records
/// enable/disable calls.
public final class FakeEventTapHandle: EventTapHandle, Sendable {
    /// CF run-loop objects are thread-safe to add, signal, wake and remove from any thread.
    private struct Installation: @unchecked Sendable {
        var source: CFRunLoopSource
        var runLoop: CFRunLoop
    }

    private struct State {
        var enabled = true
        var installed = false
        var invalidated = false
        var enableCalls: [Bool] = []
        var installation: Installation?
        var installedRunLoop: Installation?
    }

    /// Blocks run by the source's perform callback, on the thread whose run loop holds the source.
    private final class PerformQueue: Sendable {
        private let blocks = Mutex<[@Sendable () -> Void]>([])
        func append(_ block: @escaping @Sendable () -> Void) { blocks.withLock { $0.append(block) } }
        func drain() {
            let pending = blocks.withLock { blocks -> [@Sendable () -> Void] in
                defer { blocks.removeAll() }
                return blocks
            }
            for block in pending { block() }
        }
    }

    private let state = Mutex(State())
    private let queue = PerformQueue()

    public init() {}

    public func install(on runLoop: CFRunLoop) {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(queue).toOpaque()
        context.perform = { info in
            guard let info else { return }
            Unmanaged<PerformQueue>.fromOpaque(info).takeUnretainedValue().drain()
        }
        let source = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        let installation = Installation(source: source!, runLoop: runLoop)
        state.withLock {
            $0.installed = true
            $0.installation = installation
            $0.installedRunLoop = installation
        }
    }

    public func setEnabled(_ enabled: Bool) {
        state.withLock {
            $0.enabled = enabled
            $0.enableCalls.append(enabled)
        }
    }

    public var isEnabled: Bool { state.withLock { $0.enabled && !$0.invalidated } }

    public func invalidate() {
        let installation = state.withLock { state -> Installation? in
            state.invalidated = true
            state.enabled = false
            defer { state.installation = nil }
            return state.installation
        }
        if let installation { CFRunLoopRemoveSource(installation.runLoop, installation.source, .commonModes) }
    }

    /// Simulates the OS disabling the tap without a disabled event (PLT-R331 path).
    public func systemDisables() { state.withLock { $0.enabled = false } }

    /// Runs `block` on the thread whose run loop holds this handle's source, as the tap's own callbacks would
    /// run. False when the handle is not installed or already invalidated.
    @discardableResult
    public func performOnTapThread(_ block: @escaping @Sendable () -> Void) -> Bool {
        guard let installation = state.withLock({ $0.installation }) else { return false }
        queue.append(block)
        CFRunLoopSourceSignal(installation.source)
        CFRunLoopWakeUp(installation.runLoop)
        return true
    }

    public var isInstalled: Bool { state.withLock { $0.installed } }
    public var isInvalidated: Bool { state.withLock { $0.invalidated } }
    public var enableCalls: [Bool] { state.withLock { $0.enableCalls } }
    /// Identity of the run loop the source was added to (PLT-R303 tests compare it with the tap thread's).
    public var installedRunLoopIdentity: ObjectIdentifier? {
        state.withLock { $0.installedRunLoop.map { ObjectIdentifier($0.runLoop) } }
    }
}

/// Returns `FakeEventTapHandle`s, or nil while `failCreation` is set (PLT-R332 backoff tests).
public final class FakeEventTapFactory: EventTapFactory, Sendable {
    private struct State {
        var failCreation: Bool
        var handles: [FakeEventTapHandle] = []
        var masks: [TapEventMask] = []
        var userInfos: [UInt] = []
    }

    private let state: Mutex<State>

    public init(failCreation: Bool = false) { state = Mutex(State(failCreation: failCreation)) }

    public func setFailCreation(_ fail: Bool) { state.withLock { $0.failCreation = fail } }
    /// Handles created so far (PLT-R302: tests assert at most one is alive).
    public var handles: [FakeEventTapHandle] { state.withLock { $0.handles } }
    public var requestedMasks: [TapEventMask] { state.withLock { $0.masks } }
    /// `userInfo` of every request as a bit pattern (0 for nil), so a test can hand it to the callback bridge
    /// from a `@Sendable` block.
    public var userInfoBitPatterns: [UInt] { state.withLock { $0.userInfos } }

    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        state.withLock { state in
            state.masks.append(mask)
            state.userInfos.append(UInt(bitPattern: userInfo))
            guard !state.failCreation else { return nil }
            let handle = FakeEventTapHandle()
            state.handles.append(handle)
            return handle
        }
    }
}

/// `TapControl` without a thread: records enable calls and stops; `systemDisables()` turns the tap off the way
/// the OS does, without an enable call (PLT-R331 tests of `TapWatchdog`).
public final class FakeTapControl: TapControl, Sendable {
    private struct State {
        var enabled: Bool
        var running: Bool
        var enableCalls: [Bool] = []
        var stopCalls = 0
    }

    private let state: Mutex<State>

    public init(enabled: Bool = true, running: Bool = true) {
        state = Mutex(State(enabled: enabled, running: running))
    }

    public func setEnabled(_ enabled: Bool) {
        state.withLock {
            $0.enabled = enabled
            $0.enableCalls.append(enabled)
        }
    }

    public var isEnabled: Bool { state.withLock { $0.enabled && $0.running } }
    public var isRunning: Bool { state.withLock { $0.running } }

    public func stop() {
        state.withLock {
            $0.running = false
            $0.stopCalls += 1
        }
    }

    public func systemDisables() { state.withLock { $0.enabled = false } }
    public var enableCalls: [Bool] { state.withLock { $0.enableCalls } }
    public var stopCalls: Int { state.withLock { $0.stopCalls } }
}

/// Counts `reclaimAll()` calls (ADR 0303: the watchdog's 5 s tick frees retired snapshot boxes).
public final class FakeSnapshotReclaimer: SnapshotReclaiming, Sendable {
    private let calls = Atomic<Int>(0)
    public init() {}
    public func reclaimAll() { calls.wrappingAdd(1, ordering: .relaxed) }
    public var reclaimCount: Int { calls.load(ordering: .relaxed) }
}
