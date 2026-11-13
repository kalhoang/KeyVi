// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Keyboard driver of `compat-harness` (13.2). Posts the planned events through a `KeyEventSink` at absolute
// deadlines of an injected clock. The live sink (CompatHarness/Live) creates CGEvents from the harness's own
// event source so the app under test treats them as physical input; tests use `RecordingKeyEventSink` with
// `ManualClock`, so nothing is ever posted outside the self-hosted runner.

public import RealtimeSupport
internal import Synchronization

/// Destination of planned key events.
public protocol KeyEventSink: Sendable {
    func post(_ event: PlannedKeyEvent) throws
}

/// Collects events in posting order, with the clock reading at posting time.
public final class RecordingKeyEventSink: KeyEventSink, Sendable {
    public struct Record: Sendable, Hashable {
        public var event: PlannedKeyEvent
        public var postedAt: MonotonicInstant
    }

    private let clock: any MonotonicClock
    private let state = Mutex<(records: [Record], failAfter: Int?)>(([], nil))

    public init(clock: any MonotonicClock) { self.clock = clock }

    public var records: [Record] { state.withLock { $0.records } }

    /// The post after `count` successful posts throws `RecordingSinkError.injected` (cleanup tests).
    public func failAfter(_ count: Int) { state.withLock { $0.failAfter = count } }

    public func post(_ event: PlannedKeyEvent) throws {
        let now = clock.now()
        try state.withLock { state throws(RecordingSinkError) in
            if let limit = state.failAfter, state.records.count >= limit {
                state.failAfter = nil
                throw .injected
            }
            state.records.append(Record(event: event, postedAt: now))
        }
    }
}

public enum RecordingSinkError: Error, Sendable, Hashable { case injected }

public struct PhysicalKeyboardDriver: KeyboardDriver {
    private let sink: any KeyEventSink
    private let clock: any MonotonicClock
    private let seed: UInt64

    public init(sink: any KeyEventSink, clock: any MonotonicClock, seed: UInt64) {
        self.sink = sink
        self.clock = clock
        self.seed = seed
    }

    /// Posts every event at `start + offset`. On an error or cancellation it releases every key it still holds
    /// before rethrowing, so a failed run never leaves a stuck modifier behind (QA-R16).
    public func type(_ keys: [String], profile: Scenario.TimingProfile) async throws {
        try await type(keys, intervalRange: profile.intervalRange)
    }

    /// Same with explicit interval bounds in nanoseconds (C2: exactly 10 keys per second).
    public func type(_ keys: [String], intervalRange: ClosedRange<UInt64>) async throws {
        let plan = try KeyEventPlan.make(keys: keys, intervalRange: intervalRange, seed: seed)
        let start = clock.now().nanoseconds
        var held: [PlannedKeyEvent] = []
        do {
            for event in plan.events {
                try Task.checkCancellation()
                // Blocking absolute-deadline sleep (mach_wait_until in production): Task.sleep cannot hold the
                // 5 ms burst profile precisely. One scenario runs at a time, so blocking this thread is fine.
                clock.sleep(until: MonotonicInstant(nanoseconds: start &+ event.offset))
                try sink.post(event)
                Self.track(event, held: &held)
            }
        } catch {
            releaseAll(held)
            throw error
        }
    }

    private static func track(_ event: PlannedKeyEvent, held: inout [PlannedKeyEvent]) {
        switch event.phase {
        case .down: held.append(event)
        case .up: held.removeAll { $0.keyCode == event.keyCode }
        }
    }

    private func releaseAll(_ held: [PlannedKeyEvent]) {
        let offset = clock.now().nanoseconds
        for event in held.reversed() {
            let release = PlannedKeyEvent(
                offset: offset, keyCode: event.keyCode, phase: .up, isFlagsChanged: event.isFlagsChanged, flags: 0)
            try? sink.post(release)  // best effort: the original error is the one reported
        }
    }
}
