// SPDX-License-Identifier: GPL-3.0-or-later
//
// Quit sequence (PLT-R1003: pending writes are flushed before the app exits): the reply that lets AppKit end the
// process goes out exactly once, when the flush finished or when the deadline passed, and a second quit request
// starts nothing new. The flush and the reply are fakes; the deadline runs on ManualScheduler.

import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import SettingsStore

@Suite struct QuitCoordinatorTests {
    /// A flush the test finishes by hand, and a reply counter whose first call the test can await.
    final class Probe: Sendable {
        private let state = Mutex<(flushes: Int, replies: Int)>((0, 0))
        private let gate = AsyncGate()
        let replied = AsyncGate()

        var flushes: Int { state.withLock { $0.flushes } }
        var replies: Int { state.withLock { $0.replies } }

        func flush() async {
            state.withLock { $0.flushes += 1 }
            await gate.wait()
        }

        func finishFlush() { gate.open() }

        func reply() {
            state.withLock { $0.replies += 1 }
            replied.open()
        }
    }

    /// Opens once; every waiter, earlier or later, then continues.
    final class AsyncGate: Sendable {
        private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard !state.open else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.open = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    private func coordinator(_ probe: Probe, scheduler: ManualScheduler) -> QuitCoordinator {
        QuitCoordinator(
            scheduler: TimerDebounceScheduler(scheduler), deadline: .seconds(5), flush: { await probe.flush() },
            reply: { probe.reply() })
    }

    @Test func repliesOnceTheFlushFinishedAndCancelsTheDeadline() async {
        let scheduler = ManualScheduler(clock: ManualClock())
        let probe = Probe()
        let quit = coordinator(probe, scheduler: scheduler)
        #expect(quit.request() == .started)
        #expect(scheduler.pendingCount == 1, "the deadline is armed")
        probe.finishFlush()
        await probe.replied.wait()
        #expect(probe.replies == 1 && probe.flushes == 1)
        #expect(scheduler.pendingCount == 0, "the deadline is cancelled")
        scheduler.advance(by: .seconds(10))
        #expect(probe.replies == 1)
    }

    /// A flush that hangs (a stuck utility queue) must not keep the app from quitting: atomic writes leave every
    /// file either old or new, so the reply goes out at the deadline.
    @Test func repliesAtTheDeadlineWhenTheFlushHangsAndNeverTwice() async {
        let scheduler = ManualScheduler(clock: ManualClock())
        let probe = Probe()
        let quit = coordinator(probe, scheduler: scheduler)
        quit.request()
        scheduler.advance(by: .milliseconds(4_999))
        #expect(probe.replies == 0)
        scheduler.advance(by: .milliseconds(1))
        #expect(probe.replies == 1)
        probe.finishFlush()
        // The flush task ends after the deadline reply: it must not reply again.
        for _ in 0..<50 { await Task.yield() }
        #expect(probe.replies == 1)
    }

    @Test func aSecondRequestStartsNoSecondFlush() async {
        let scheduler = ManualScheduler(clock: ManualClock())
        let probe = Probe()
        let quit = coordinator(probe, scheduler: scheduler)
        #expect(quit.request() == .started)
        #expect(quit.request() == .alreadyRunning)
        #expect(scheduler.pendingCount == 1)
        probe.finishFlush()
        await probe.replied.wait()
        #expect(probe.flushes == 1 && probe.replies == 1)
        #expect(quit.request() == .alreadyRunning)
    }

    @Test func theDefaultDeadlineLeavesTheHarnessQuitWaitRoom() {
        // compat-harness waits 10 s for the process to exit (LiveAppControl.quitTimeoutNanoseconds).
        #expect(QuitCoordinator.defaultDeadline == .seconds(5))
    }
}
