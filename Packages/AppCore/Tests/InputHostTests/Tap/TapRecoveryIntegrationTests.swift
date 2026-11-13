// SPDX-License-Identifier: LicenseRef-App-Pending
//
// TapThread + TapWatchdog + HostLifecycle with fakes: the effects are performed the way InputHostController
// will perform them, and the factory proves that a stuck callback never leads to a second tap (PLT-R302,
// ADR 0309). W1-F2.
import AppModel
import RealtimeSupport
import Synchronization
import TestSupport
import Testing

@testable import InputHost

/// Minimal effect performer: one TapThread at a time, created from the factory on `.createTap`.
private final class EffectPerformer {
    let factory: FakeEventTapFactory
    private(set) var current: TapThread<TrivialHandler>?
    private(set) var lifecycle = HostLifecycle()
    private var now = MonotonicInstant(nanoseconds: 1_000_000_000)

    init(factory: FakeEventTapFactory) { self.factory = factory }

    func send(_ input: LifecycleInput) {
        var pending = [input]
        while !pending.isEmpty {
            let effects = lifecycle.handle(pending.removeFirst(), at: now)
            for effect in effects { pending += perform(effect) }
        }
    }

    private func perform(_ effect: LifecycleEffect) -> [LifecycleInput] {
        switch effect {
        case .createTap:
            let thread = TapThread(factory: factory) { TrivialHandler(probe: HandlerProbe()) }
            guard thread.start() else { return [.tapCreationFailed] }
            current = thread
            return [.tapCreated]
        case .removeTap:
            current?.stop()
            _ = current?.waitUntilExited(timeout: .seconds(5))
            current = nil
        case .disableTap: current?.setEnabled(false)
        case .reenableTap: current?.setEnabled(true)
        default: break
        }
        return []
    }
}

@Suite struct TapRecoveryIntegrationTests {
    @Test func stuckCallbackNeverRequestsASecondHandle_PLT_R302_ADR0309() throws {
        let factory = FakeEventTapFactory()
        let performer = EffectPerformer(factory: factory)
        performer.send(.launched)
        performer.send(.permissionsChanged(.granted))
        let thread = try #require(performer.current)
        #expect(performer.lifecycle.phase == .running)

        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let callbacks = CallbackWatchdog(activitySignal: nil)
        let inbox = Mutex<[LifecycleInput]>([])
        let watchdog = TapWatchdog(
            tap: thread, callbacks: callbacks, snapshots: FakeSnapshotReclaimer(), scheduler: scheduler,
            clock: clock, onCallbackReturned: { inbox.withLock { $0.append(.callbackExited) } },
            onTrip: { trip in inbox.withLock { $0.append(.watchdogTripped(trip)) } })
        watchdog.start()
        defer { watchdog.stop() }
        func deliverReports() {
            let inputs = inbox.withLock { inputs -> [LifecycleInput] in
                defer { inputs.removeAll() }
                return inputs
            }
            for input in inputs { performer.send(input) }
        }

        callbacks.enter(at: clock.now())  // the callback never returns
        watchdog.callbackActivity()
        scheduler.advance(by: .seconds(3))
        deliverReports()
        #expect(performer.lifecycle.phase == .failOpen(.callbackStuck))
        #expect(!thread.isEnabled, "keys flow past the disabled tap")

        for input: LifecycleInput in [
            .permissionsChanged(.denied), .permissionsChanged(.granted), .retryTimerFired, .sessionActive(false),
            .sessionActive(true), .tapDisabledBySystem(byTimeout: true),
        ] {
            performer.send(input)
            scheduler.advance(by: .seconds(5))
            deliverReports()
        }
        #expect(factory.handles.count == 1, "no second tap while the old callback may be stuck")
        #expect(thread.isRunning, "the stuck thread is never stopped")
        #expect(performer.lifecycle.phase == .failOpen(.callbackStuck))

        callbacks.exit()  // the callback finally returns
        scheduler.advance(by: .seconds(5))
        deliverReports()
        #expect(performer.lifecycle.phase == .running)
        #expect(thread.isEnabled, "the same tap is re-enabled")
        #expect(factory.handles.count == 1)
        performer.send(.permissionsChanged(.denied))
        #expect(!thread.isRunning)
    }

    @Test func returnedCallbackRecoversTheSameTapWithinTwoSeconds_PLT_R306() throws {
        let factory = FakeEventTapFactory()
        let performer = EffectPerformer(factory: factory)
        performer.send(.launched)
        performer.send(.permissionsChanged(.granted))
        let thread = try #require(performer.current)
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let callbacks = CallbackWatchdog(activitySignal: nil)
        let inbox = Mutex<[LifecycleInput]>([])
        let watchdog = TapWatchdog(
            tap: thread, callbacks: callbacks, snapshots: FakeSnapshotReclaimer(), scheduler: scheduler,
            clock: clock, onCallbackReturned: { inbox.withLock { $0.append(.callbackExited) } },
            onTrip: { trip in inbox.withLock { $0.append(.watchdogTripped(trip)) } })
        watchdog.start()
        defer {
            watchdog.stop()
            thread.stop()
        }
        callbacks.enter(at: clock.now())
        watchdog.callbackActivity()
        scheduler.advance(by: .milliseconds(300))
        #expect(!thread.isEnabled, "the watchdog disabled the tap itself")
        callbacks.exit()
        scheduler.advance(by: .seconds(2))
        for input in inbox.withLock({ $0 }) { performer.send(input) }
        #expect(performer.lifecycle.phase == .running)
        #expect(thread.isEnabled)
        #expect(factory.handles.count == 1)
    }
}
