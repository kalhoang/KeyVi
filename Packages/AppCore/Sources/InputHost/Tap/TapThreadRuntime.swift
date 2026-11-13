// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The non-generic part of `TapThread` (PLT-R203, PLT-R303): the dedicated thread, its CFRunLoop with only the
// tap source, and the state the owner and the watchdog read from other threads. Workstream W1-F2.

internal import CoreFoundation
internal import Dispatch
internal import Foundation
internal import Synchronization

final class TapThreadRuntime: Sendable {
    /// Built on the tap thread and kept there: the handle and the object `userInfo` points at, which owns the
    /// handler. Never crosses threads (ADR 0313), so it need not be Sendable.
    struct Session {
        let handle: any EventTapHandle
        let target: TapCallbackTarget
    }

    static let threadName = "tap"

    private enum Phase: Sendable, Hashable { case idle, starting, running, exited }

    /// CFRunLoop has no Sendable annotation; stopping and waking a run loop from another thread is thread-safe.
    private struct State: @unchecked Sendable {
        var phase = Phase.idle
        var stopRequested = false
        /// The factory returned a handle and the thread entered its run loop.
        var tapCreated = false
        var handle: (any EventTapHandle)?
        var runLoop: CFRunLoop?
    }

    private let state = Mutex(State())
    private let exited = DispatchGroup()

    /// Spawns the thread, waits until `makeSession` (run on that thread) has created the tap or failed.
    func start(_ makeSession: @escaping @Sendable () -> Session?) -> Bool {
        let begin = state.withLock { state -> Bool? in
            guard state.phase == .idle, !state.stopRequested else { return state.phase == .running ? true : false }
            state.phase = .starting
            return nil
        }
        if let begin { return begin }
        let created = DispatchSemaphore(value: 0)
        exited.enter()
        let thread = Thread { [self] in
            run(makeSession, created: created)
            exited.leave()
        }
        thread.name = Self.threadName
        thread.qualityOfService = .userInteractive
        thread.start()
        created.wait()
        return state.withLock { $0.tapCreated }
    }

    func setEnabled(_ enabled: Bool) { liveHandle()?.setEnabled(enabled) }
    var isEnabled: Bool { liveHandle()?.isEnabled ?? false }
    var isRunning: Bool { state.withLock { $0.phase == .running } }

    func stop() {
        let (handle, runLoop) = state.withLock { state -> ((any EventTapHandle)?, CFRunLoop?) in
            state.stopRequested = true
            defer { state.handle = nil }
            return (state.handle, state.runLoop)
        }
        handle?.setEnabled(false)
        handle?.invalidate()
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    func waitUntilExited(timeout: Duration) -> Bool {
        exited.wait(timeout: .now() + .nanoseconds(Int(clamping: timeout.nanoseconds))) == .success
    }

    // MARK: - Tap thread

    private func run(_ makeSession: () -> Session?, created: DispatchSemaphore) {
        let runLoop = CFRunLoopGetCurrent()!
        guard let session = makeSession() else {
            state.withLock { $0.phase = .exited }
            created.signal()
            return
        }
        session.handle.install(on: runLoop)
        let proceed = state.withLock { state -> Bool in
            guard !state.stopRequested else { return false }
            state.phase = .running
            state.tapCreated = true
            state.handle = session.handle
            state.runLoop = runLoop
            return true
        }
        if proceed {
            created.signal()
            runUntilStopped()
        } else {
            session.handle.setEnabled(false)
            session.handle.invalidate()
        }
        state.withLock {
            $0.phase = .exited
            $0.runLoop = nil
        }
        if !proceed { created.signal() }
        // `session` (and the handler) is released here, on the tap thread.
        withExtendedLifetime(session) {}
    }

    /// The run loop holds only the tap source (PLT-R303). It returns when `stop()` stops it or the source is
    /// gone; the lock is taken only then, never inside a callback (PLT-R305).
    private func runUntilStopped() {
        while !state.withLock({ $0.stopRequested }) {
            if CFRunLoopRunInMode(.defaultMode, 1.0e10, false) == .finished { break }
        }
    }

    private func liveHandle() -> (any EventTapHandle)? {
        state.withLock { $0.phase == .running && !$0.stopRequested ? $0.handle : nil }
    }
}
