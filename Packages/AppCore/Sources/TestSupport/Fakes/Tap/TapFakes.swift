// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Event tap fakes (ADR 0313): never create a real tap and never talk to the WindowServer. Implemented in the
// skeleton; workstream W1-F2 owns this directory and may add behaviours.

public import CoreFoundation
public import CoreGraphics
public import InputHost
internal import Synchronization

/// Pure Swift tap handle. `install` adds an inert run-loop source (so the tap thread's run loop has a source
/// and keeps running) and records enable/disable calls.
public final class FakeEventTapHandle: EventTapHandle, Sendable {
    /// CF run-loop objects are thread-safe to add and remove from any thread.
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
    }

    private let state = Mutex(State())

    public init() {}

    public func install(on runLoop: CFRunLoop) {
        var context = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        let installation = Installation(source: source!, runLoop: runLoop)
        state.withLock {
            $0.installed = true
            $0.installation = installation
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

    public var isInstalled: Bool { state.withLock { $0.installed } }
    public var isInvalidated: Bool { state.withLock { $0.invalidated } }
    public var enableCalls: [Bool] { state.withLock { $0.enableCalls } }
}

/// Returns `FakeEventTapHandle`s, or nil while `failCreation` is set (PLT-R332 backoff tests).
public final class FakeEventTapFactory: EventTapFactory, Sendable {
    private struct State {
        var failCreation: Bool
        var handles: [FakeEventTapHandle] = []
        var masks: [TapEventMask] = []
    }

    private let state: Mutex<State>

    public init(failCreation: Bool = false) { state = Mutex(State(failCreation: failCreation)) }

    public func setFailCreation(_ fail: Bool) { state.withLock { $0.failCreation = fail } }
    /// Handles created so far (PLT-R302: tests assert at most one is alive).
    public var handles: [FakeEventTapHandle] { state.withLock { $0.handles } }
    public var requestedMasks: [TapEventMask] { state.withLock { $0.masks } }

    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        state.withLock { state in
            state.masks.append(mask)
            guard !state.failCreation else { return nil }
            let handle = FakeEventTapHandle()
            state.handles.append(handle)
            return handle
        }
    }
}
