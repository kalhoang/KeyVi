// SPDX-License-Identifier: LicenseRef-App-Pending
//
// TapThread with FakeEventTapFactory (PLT-R203, PLT-R301-R303, PLT-R332, PLT-R730, ADR 0313). No real tap is
// ever created: the fake handle installs an inert run-loop source. W1-F2.
import AppModel
import CoreFoundation
import CoreGraphics
import Dispatch
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

/// Where something ran.
struct ThreadStamp: Hashable, Sendable {
    var thread: UInt
    var isMain: Bool
    var qualityOfService: QualityOfService
    var runLoop: ObjectIdentifier

    static var current: ThreadStamp {
        ThreadStamp(
            thread: UInt(bitPattern: pthread_self()), isMain: Thread.isMainThread,
            qualityOfService: Thread.current.qualityOfService, runLoop: ObjectIdentifier(CFRunLoopGetCurrent()))
    }
}

/// Records what the trivial handler saw (workstreams.md: "a trivial TapEventHandler written in its tests").
final class HandlerProbe: Sendable {
    private struct State {
        var created: ThreadStamp?
        var released: ThreadStamp?
        var events: [(RawKeyEvent.Kind, ThreadStamp)] = []
    }

    private let state = Mutex(State())

    func created() { state.withLock { $0.created = .current } }
    func released() { state.withLock { $0.released = .current } }
    func handled(_ event: RawKeyEvent) { state.withLock { $0.events.append((event.kind, .current)) } }

    var creation: ThreadStamp? { state.withLock { $0.created } }
    var release: ThreadStamp? { state.withLock { $0.released } }
    var events: [(RawKeyEvent.Kind, ThreadStamp)] { state.withLock { $0.events } }
}

/// Swallows keyDowns, passes everything else. Not Sendable: it lives on the tap thread only.
final class TrivialHandler: TapEventHandler {
    let probe: HandlerProbe
    init(probe: HandlerProbe) {
        self.probe = probe
        probe.created()
    }
    deinit { probe.released() }
    func handle(_ event: RawKeyEvent) -> TapVerdict {
        probe.handled(event)
        return event.kind == .keyDown ? .swallow : .pass
    }
}

func rawEvent(_ kind: RawKeyEvent.Kind) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 40, unicode: .empty,
        userData: 0, receivedAt: MonotonicInstant(nanoseconds: 1))
}

/// Delivers `event` through the callback bridge on the tap thread and waits for the verdict (nil when the
/// handle is gone or the block did not run within `timeout`, for example because the tap stopped first).
func deliverOnTapThread(
    _ event: RawKeyEvent, handle: FakeEventTapHandle, userInfo: UInt, timeout: DispatchTimeInterval = .seconds(5)
) -> TapVerdict? {
    let verdict = Mutex<TapVerdict?>(nil)
    let done = DispatchSemaphore(value: 0)
    let scheduled = handle.performOnTapThread {
        let pointer = UnsafeMutableRawPointer(bitPattern: userInfo)!
        let result = TapCallbackBridge.deliver(event, userInfo: pointer)
        verdict.withLock { $0 = result }
        done.signal()
    }
    guard scheduled, done.wait(timeout: .now() + timeout) == .success else { return nil }
    return verdict.withLock { $0 }
}

private let waitLimit: TimeSpan = .seconds(5)

@Suite struct TapThreadLifecycleTests {
    @Test func startFailsWhenTheFactoryReturnsNil_PLT_R332() {
        let factory = FakeEventTapFactory(failCreation: true)
        let probe = HandlerProbe()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: probe) }
        #expect(!thread.start())
        #expect(!thread.isRunning)
        #expect(!thread.isEnabled)
        #expect(factory.handles.isEmpty)
        #expect(thread.waitUntilExited(timeout: waitLimit))
        #expect(probe.release == probe.creation, "the handler lived and died on the tap thread")
        #expect(!thread.start(), "a TapThread is single-use")
        #expect(factory.requestedMasks.count == 1)
    }

    @Test func handlerIsCreatedOnTheTapThreadWhoseRunLoopHoldsTheTap_PLT_R303() throws {
        let factory = FakeEventTapFactory()
        let probe = HandlerProbe()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: probe) }
        #expect(thread.start())
        defer { thread.stop() }
        let creation = try #require(probe.creation)
        let handle = try #require(factory.handles.first)
        #expect(!creation.isMain)
        #expect(creation.thread != ThreadStamp.current.thread)
        #expect(creation.qualityOfService == .userInteractive, "PLT-R203: tap thread QoS")
        #expect(handle.installedRunLoopIdentity == creation.runLoop, "the tap source is on the tap thread's run loop")
        #expect(thread.isRunning)
        #expect(thread.isEnabled)
    }

    @Test func stopInvalidatesTheHandleAndTheRunLoopExits_PLT_R730() throws {
        let factory = FakeEventTapFactory()
        let probe = HandlerProbe()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: probe) }
        #expect(thread.start())
        let handle = try #require(factory.handles.first)
        thread.stop()
        #expect(handle.isInvalidated)
        #expect(handle.enableCalls.last == false, "disabled before removal")
        #expect(thread.waitUntilExited(timeout: waitLimit))
        #expect(!thread.isRunning)
        #expect(!thread.isEnabled)
        #expect(probe.release != nil)
        #expect(probe.release == probe.creation, "the handler is released on the tap thread")
        thread.stop()  // idempotent
    }

    @Test func standardMaskIncludesScrollWheel_PRD_R14_PLT_R301() {
        let factory = FakeEventTapFactory()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: HandlerProbe()) }
        #expect(thread.start())
        defer { thread.stop() }
        #expect(factory.requestedMasks == [.standard])
        #expect(factory.requestedMasks.first?.includeScrollWheel == true)
        let scroll = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        #expect(TapEventMask.standard.cgMask & scroll != 0)
    }

    @Test func enableCallsReachTheHandle() throws {
        let factory = FakeEventTapFactory()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: HandlerProbe()) }
        #expect(thread.start())
        defer { thread.stop() }
        thread.setEnabled(false)
        #expect(!thread.isEnabled)
        thread.setEnabled(true)
        #expect(thread.isEnabled)
        #expect(try #require(factory.handles.first).enableCalls == [false, true])
    }

    @Test func oneTapPerThread_PLT_R302() {
        let factory = FakeEventTapFactory()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: HandlerProbe()) }
        #expect(thread.start())
        #expect(thread.start(), "already running")
        #expect(factory.handles.count == 1)
        thread.stop()
        #expect(thread.waitUntilExited(timeout: waitLimit))
        #expect(!thread.start(), "recreation needs a fresh TapThread (ADR 0309)")
        #expect(factory.handles.count == 1)
    }

    @Test func stopBeforeStartIsSafeAndPreventsStarting() {
        let factory = FakeEventTapFactory()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: HandlerProbe()) }
        #expect(thread.waitUntilExited(timeout: .zero), "never started")
        thread.stop()
        #expect(!thread.start())
        #expect(factory.handles.isEmpty)
    }

    @Test func stopDuringCreationRemovesTheNewTapAndFailsTheStart() throws {
        let factory = StoppingFactory()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: HandlerProbe()) }
        factory.onMake = { thread.stop() }
        #expect(!thread.start())
        let handle = try #require(factory.inner.handles.first)
        #expect(handle.isInvalidated)
        #expect(handle.enableCalls == [false])
        #expect(thread.waitUntilExited(timeout: waitLimit))
        #expect(!thread.isRunning)
    }

    @Test func releasingTheTapThreadStopsIt() throws {
        let factory = FakeEventTapFactory()
        let probe = HandlerProbe()
        do {
            let thread = TapThread(factory: factory) { TrivialHandler(probe: probe) }
            #expect(thread.start())
        }
        #expect(try #require(factory.handles.first).isInvalidated)
    }
}

/// Calls `onMake` from inside `makeTap` (on the tap thread), then creates a fake handle.
final class StoppingFactory: EventTapFactory, Sendable {
    let inner = FakeEventTapFactory()
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    var onMake: (@Sendable () -> Void)? {
        get { hook.withLock { $0 } }
        set { hook.withLock { $0 = newValue } }
    }

    func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        onMake?()
        return inner.makeTap(mask: mask, callback: callback, userInfo: userInfo)
    }
}

@Suite struct TapCallbackBridgeTests {
    @Test func targetWithoutHandlerPassesEverything_PRD_R44() {
        #expect(TapCallbackTarget().dispatch(rawEvent(.keyDown)) == .pass)
    }

    @Test func eventsReachTheHandlerOnTheTapThreadThroughUserInfo() throws {
        let factory = FakeEventTapFactory()
        let probe = HandlerProbe()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: probe) }
        #expect(thread.start())
        defer { thread.stop() }
        let handle = try #require(factory.handles.first)
        let userInfo = try #require(factory.userInfoBitPatterns.first)
        #expect(userInfo != 0, "userInfo points at the tap thread's state")
        #expect(deliverOnTapThread(rawEvent(.keyDown), handle: handle, userInfo: userInfo) == .swallow)
        #expect(deliverOnTapThread(rawEvent(.keyUp), handle: handle, userInfo: userInfo) == .pass)
        #expect(deliverOnTapThread(rawEvent(.scrollWheel), handle: handle, userInfo: userInfo) == .pass)
        let events = probe.events
        #expect(events.map(\.0) == [.keyDown, .keyUp, .scrollWheel])
        #expect(events.allSatisfy { $0.1 == probe.creation }, "every callback runs on the tap thread")
    }

    @Test func eventTypesMapToRawKinds_PLT_R301() {
        let mapped: [(CGEventType, RawKeyEvent.Kind)] = [
            (.keyDown, .keyDown), (.keyUp, .keyUp), (.flagsChanged, .flagsChanged),
            (.leftMouseDown, .leftMouseDown), (.rightMouseDown, .rightMouseDown),
            (.otherMouseDown, .otherMouseDown), (.scrollWheel, .scrollWheel),
            (.tapDisabledByTimeout, .tapDisabledByTimeout), (.tapDisabledByUserInput, .tapDisabledByUserInput),
        ]
        for (type, kind) in mapped { #expect(RawKeyEvent.Kind(type) == kind) }
        for type: CGEventType in [.null, .mouseMoved, .leftMouseUp, .leftMouseDragged] {
            #expect(RawKeyEvent.Kind(type) == nil, "not in the mask: passed without calling the handler")
        }
    }

    @Test func standardMaskCoversExactlyTheMappedEventKinds() {
        let mask = TapEventMask.standard.cgMask
        for raw in 0..<32 {
            guard let type = CGEventType(rawValue: UInt32(raw)) else { continue }
            let inMask = mask & (CGEventMask(1) << CGEventMask(raw)) != 0
            #expect(inMask == (RawKeyEvent.Kind(type) != nil), "\(raw)")
        }
    }
}

/// Thread Sanitizer target: the watchdog (utility) and the owner (main) use `TapControl` while events run on
/// the tap thread and the owner stops it.
@Suite struct TapThreadConcurrencyTests {
    @Test func controlFromSeveralThreadsWhileEventsFlowAndStop() throws {
        let factory = FakeEventTapFactory()
        let probe = HandlerProbe()
        let thread = TapThread(factory: factory) { TrivialHandler(probe: probe) }
        #expect(thread.start())
        let handle = try #require(factory.handles.first)
        let userInfo = try #require(factory.userInfoBitPatterns.first)
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for step in 0..<500 {
                switch worker {
                case 0: thread.setEnabled(step % 2 == 0)
                case 1: _ = thread.isEnabled && thread.isRunning
                case 2:
                    _ = deliverOnTapThread(
                        rawEvent(.keyUp), handle: handle, userInfo: userInfo, timeout: .milliseconds(50))
                default: if step == 250 { thread.stop() }
                }
            }
        }
        #expect(thread.waitUntilExited(timeout: .seconds(5)))
        #expect(!thread.isRunning)
        #expect(probe.events.allSatisfy { $0.1 == probe.creation })
    }
}
