// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Record typing trace..." (PLT-R905, D26) around `CaptureController`: start after the confirmation, a
// one-second countdown for the HUD while recording, the end by Stop or by the time limit, then review, export
// or discard. The trace is the only artefact with typed characters; it is deleted right after export or discard
// and otherwise after 24 hours by `CaptureController.purgeExpired`.

public import AppModel
public import Diagnostics
public import Foundation
public import RealtimeSupport
internal import Synchronization

public final class TypingTraceSession: Sendable {
    public enum State: Sendable, Hashable {
        case idle
        /// The menu icon changes and the HUD shows `remaining` with a Stop button for the whole recording.
        case recording(CaptureSessionID, remaining: Duration)
        /// Stopped by the user or the time limit: ready for review.
        case finished(CaptureSessionID)
        case exported
        case discarded
        case failed(Failure)
    }

    public enum Failure: Sendable, Hashable {
        case alreadyRecording, invalidDuration, unknownSession, storage
    }

    /// HUD countdown period. User-initiated and visible, so not a steady-state timer (PLT-R803).
    public static let tick: Duration = .seconds(1)

    /// The duration the user picked, clamped to 1...180 s (PLT-R905); 60 s by default.
    public static func duration(seconds: Int?) -> Duration {
        guard let seconds else { return CaptureLimits.defaultDuration }
        let maximum = Int(CaptureLimits.maximumDuration.components.seconds)
        return .seconds(min(max(seconds, 1), maximum))
    }

    private struct Inner: ~Copyable {
        var state: State = .idle
        var timer: (any ScheduledTimer)?
    }

    private let capture: CaptureController
    private let scheduler: any TimerScheduler
    private let wallClock: any WallClock
    private let onChange: @Sendable (State) -> Void
    private let inner = Mutex(Inner())

    /// `onChange` runs on the caller's thread for user actions and on the scheduler's queue for ticks.
    public init(
        capture: CaptureController, scheduler: any TimerScheduler, wallClock: any WallClock,
        onChange: @escaping @Sendable (State) -> Void
    ) {
        self.capture = capture
        self.scheduler = scheduler
        self.wallClock = wallClock
        self.onChange = onChange
    }

    public var state: State { inner.withLock { $0.state } }

    /// Explicit user action after the confirmation that explains what is recorded (PLT-R905).
    public func start(duration: Duration = CaptureLimits.defaultDuration) {
        switch state {
        case .recording: return  // one trace at a time; the HUD's Stop ends it
        case .finished(let previous): capture.discard(previous)  // an unreviewed trace never lingers
        default: break
        }
        let next: State
        do {
            let info = try capture.start(duration: duration)
            let timer = scheduler.scheduleRepeating(every: Self.tick, leeway: .milliseconds(100)) { [weak self] in
                self?.tickElapsed()
            }
            next = .recording(info.id, remaining: duration)
            inner.withLock {
                $0.timer?.cancel()
                $0.timer = timer
            }
        } catch let error as CaptureError {
            next = .failed(Self.failure(error))
        } catch {
            next = .failed(.storage)
        }
        publish(next)
    }

    /// Stop button of the HUD.
    public func stop() {
        guard case .recording(let id, _) = state else { return }
        _ = capture.stop()
        finish(id)
    }

    /// Readable rendering for the review window (PLT-R905); nil (and `.failed`) when the trace is gone.
    public func review(language: InterfaceLanguage) -> String? {
        guard case .finished(let id) = state else { return nil }
        do {
            return try capture.render(id, language: language)
        } catch {
            publish(.failed(Self.failure(error)))
            return nil
        }
    }

    /// Writes the JSON-lines trace to `destination` (chosen in a save panel) and deletes the capture.
    @discardableResult
    public func export(to destination: URL) -> Bool {
        guard case .finished(let id) = state else { return false }
        do {
            try capture.export(id, to: destination)
            publish(.exported)
            return true
        } catch {
            publish(.failed(Self.failure(error)))
            return false
        }
    }

    /// Deletes the trace at once (also when the review window closes without export).
    public func discard() {
        switch state {
        case .recording(let id, _), .finished(let id):
            cancelTimer()
            capture.discard(id)
            publish(.discarded)
        default:
            return
        }
    }

    private func tickElapsed() {
        guard case .recording(let id, _) = state else { return }
        guard let remaining = capture.remaining(now: wallClock.now()), remaining > .zero else {
            // The capture's own time limit ended the session (or is due): show the review.
            _ = capture.stop()
            finish(id)
            return
        }
        let updated = inner.withLock { inner -> Bool in
            guard case .recording(let current, _) = inner.state, current == id else { return false }
            inner.state = .recording(id, remaining: remaining)
            return true
        }
        if updated { onChange(.recording(id, remaining: remaining)) }
    }

    /// Recording -> finished exactly once, whether Stop or the time limit comes first.
    private func finish(_ id: CaptureSessionID) {
        let (moved, timer) = inner.withLock { inner -> (Bool, (any ScheduledTimer)?) in
            guard case .recording(let current, _) = inner.state, current == id else { return (false, nil) }
            inner.state = .finished(id)
            defer { inner.timer = nil }
            return (true, inner.timer)
        }
        timer?.cancel()
        if moved { onChange(.finished(id)) }
    }

    private func cancelTimer() {
        let timer = inner.withLock { inner -> (any ScheduledTimer)? in
            defer { inner.timer = nil }
            return inner.timer
        }
        timer?.cancel()
    }

    private func publish(_ state: State) {
        inner.withLock { $0.state = state }
        onChange(state)
    }

    static func failure(_ error: any Error) -> Failure {
        switch error as? CaptureError {
        case .alreadyRecording?: .alreadyRecording
        case .invalidDuration?: .invalidDuration
        case .unknownSession?: .unknownSession
        case .storage?, nil: .storage
        }
    }
}
