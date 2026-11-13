// SPDX-License-Identifier: GPL-3.0-or-later
//
// Quit sequence of the app (PLT-R1003: pending settings writes are flushed before the process ends). AppKit keeps
// the app alive until it gets the reply to `applicationShouldTerminate`; this type decides when that reply goes
// out: exactly once, as soon as the flush finished or when the deadline passed, whichever comes first. A second
// quit request while one runs starts nothing new. Ending a slow flush early is safe because every write is atomic
// (temporary file, fsync, rename): each file is either its old or its new version.
//
// The flush runs off the main actor and `reply` is the app's own delivery (App: performed by the main run loop,
// not the main dispatch queue). A quit requested from inside a main-queue job, such as `NSApp.terminate` called
// from a main-actor task or a modal alert opened from `DispatchQueue.main.async`, blocks that queue until the job
// ends, so a reply sent through it never arrived and the app never quit (seen in the VM, integration-suite.md
// section 10).

public import RealtimeSupport

public final class QuitCoordinator: Sendable {
    public enum Request: Sendable, Hashable {
        /// This request started the flush and the deadline.
        case started
        /// A quit is already under way; its reply answers this request too.
        case alreadyRunning
    }

    /// compat-harness waits 10 s for the process to end; a person expects a menu-bar app to be gone at once.
    public static let defaultDeadline = TimeSpan.seconds(5)

    private struct State {
        var started = false
        var replied = false
        var deadline: (any DebounceTimer)?
    }

    private let state = Mutex(State())
    private let scheduler: any DebounceScheduler
    private let deadline: TimeSpan
    private let flush: @Sendable () async -> Void
    private let reply: @Sendable () -> Void

    /// `flush` writes everything pending (settings, logs); `reply` lets the app end, from any thread.
    public init(
        scheduler: any DebounceScheduler, deadline: TimeSpan = QuitCoordinator.defaultDeadline,
        flush: @escaping @Sendable () async -> Void, reply: @escaping @Sendable () -> Void
    ) {
        self.scheduler = scheduler
        self.deadline = deadline
        self.flush = flush
        self.reply = reply
    }

    /// Starts the flush and arms the deadline on the first call; later calls only report that a quit runs.
    @discardableResult
    public func request() -> Request {
        let first = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard first else { return .alreadyRunning }
        let timer = scheduler.schedule(after: deadline) { [self] in finish() }
        let alreadyReplied = state.withLock { state -> Bool in
            if !state.replied { state.deadline = timer }
            return state.replied
        }
        if alreadyReplied { timer.cancel() }
        let flush = self.flush
        Task.detached { [self] in
            await flush()
            finish()
        }
        return .started
    }

    /// Sends the reply unless it went out already, and disarms the deadline.
    private func finish() {
        let (send, timer) = state.withLock { state -> (Bool, (any DebounceTimer)?) in
            guard !state.replied else { return (false, nil) }
            state.replied = true
            defer { state.deadline = nil }
            return (true, state.deadline)
        }
        timer?.cancel()
        if send { reply() }
    }
}
