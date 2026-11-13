// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `paste` (4.6) with full clipboard preservation (PLT-R461). Opt-in only (PLT-R460); the worker filters it out
// of the strategy chain unless `pasteOptedIn` is set.

internal import AppModel
internal import RealtimeSupport

/// State behind `PasteboardPreserver` (inject thread only).
struct PasteSession {
    struct Pending {
        var snapshot: PasteboardSnapshot
        /// `changeCount` right after the transient item was written (PLT-R461 step 2).
        var transientChangeCount: Int
        /// Start of the restore window; nil until the worker arms it after Command+V.
        var armedAt: MonotonicInstant?
    }

    let pasteboard: any PasteboardAccess
    let limits: PasteboardLimits
    private(set) var pending: Pending?
    /// Restores skipped because the user copied something while a paste was pending (health events).
    private(set) var skippedRestores = 0

    init(pasteboard: any PasteboardAccess, limits: PasteboardLimits) {
        self.pasteboard = pasteboard
        self.limits = limits
    }

    /// Steps 1-2 and 6. Inside the window the pasteboard still holds our transient item, so the first snapshot
    /// is kept (coalescing). If the user copied in between, that copy is what must survive: take a new snapshot.
    mutating func begin(_ text: String) throws(PasteboardError) {
        if let current = pending, pasteboard.changeCount != current.transientChangeCount {
            pending = nil
            skippedRestores += 1
        }
        let snapshot: PasteboardSnapshot
        if let kept = pending?.snapshot {
            snapshot = kept
        } else {
            snapshot = try pasteboard.snapshot(limits: limits)
        }
        do {
            let changeCount = try pasteboard.writeTransient(text)
            pending = Pending(snapshot: snapshot, transientChangeCount: changeCount, armedAt: nil)
        } catch {
            // The write may have cleared the pasteboard: put the saved items back now.
            try? pasteboard.restore(snapshot)
            pending = nil
            throw error
        }
    }

    mutating func arm(at now: MonotonicInstant) {
        pending?.armedAt = now
    }

    func deadline(restoreDelay: Duration) -> MonotonicInstant? {
        guard let armedAt = pending?.armedAt else { return nil }
        return MonotonicInstant(nanoseconds: armedAt.nanoseconds &+ InjectionTiming.nanoseconds(restoreDelay))
    }

    /// Steps 4-5. Restores only if `changeCount` still equals the value from step 2. A restore that cannot be
    /// written is reported as skipped: the pending item is dropped rather than retried forever.
    mutating func restoreIfDue(now: MonotonicInstant, restoreDelay: Duration) -> PasteboardPreserver.RestoreResult {
        guard let current = pending else { return .nothingPending }
        if current.armedAt == nil { arm(at: now) }
        guard let due = deadline(restoreDelay: restoreDelay), now >= due else { return .notDue }
        pending = nil
        guard pasteboard.changeCount == current.transientChangeCount else { return .skippedUserCopied }
        do {
            try pasteboard.restore(current.snapshot)
            return .restored
        } catch {
            return .skippedUserCopied
        }
    }

    /// The paste was abandoned before Command+V: restore immediately.
    mutating func restoreNow() {
        guard let current = pending else { return }
        pending = nil
        if pasteboard.changeCount == current.transientChangeCount { try? pasteboard.restore(current.snapshot) }
    }

    mutating func takeSkippedRestores() -> Int {
        defer { skippedRestores = 0 }
        return skippedRestores
    }
}

extension PasteboardPreserver {
    var hasPendingRestore: Bool { session.pending != nil }
    func arm(at now: MonotonicInstant) { session.arm(at: now) }
    func deadline(restoreDelay: Duration) -> MonotonicInstant? { session.deadline(restoreDelay: restoreDelay) }
    func restoreNow() { session.restoreNow() }
    func takeSkippedRestores() -> Int { session.takeSkippedRestores() }
}

/// PLT-R461 steps 1-4. Without a `StrategyHost` (strategy tests with a plain environment) the executor uses its
/// own preserver and waits for the restore inline, which is correct but blocks; the worker never does that.
struct PasteExecutor: StrategyExecutor {
    let limits: StrategyLimits
    var strategy: InjectionStrategy { .paste }

    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome {
        guard let pasteKey = job.keyCodes.paste else { return .failedBeforePosting(.pasteboardUnsafe) }
        let host = environment as? any StrategyHost
        let preserver = host?.pasteboardPreserver ?? PasteboardPreserver(pasteboard: environment.pasteboard)
        do {
            try preserver.beginPaste(job.insertion)
        } catch {
            return .failedBeforePosting(.pasteboardUnsafe)
        }
        var script = KeyScript()
        script.append(SyntheticKeys.backspace, phase: .delete, count: job.deleteCount)
        script.append(SyntheticKeys.paste(keyCode: pasteKey), phase: .insert)
        let outcome = ScriptRunner.run(script, job: job, limits: limits, in: environment)
        let restoreDelay = Duration.milliseconds(max(0, job.plan.parameters.restoreDelayMs))
        switch outcome {
        case .failedBeforePosting:
            preserver.restoreNow()
            return outcome
        case .completed, .failedAfterPosting:
            // Step 4: the ordering guarantee covers only the deletions and Command+V.
            environment.releaseHeldEvents()
            if let host {
                host.pasteCompleted(restoreDelay: restoreDelay)
            } else {
                Self.restoreInline(preserver, restoreDelay: restoreDelay, in: environment)
            }
            return outcome
        }
    }

    private static func restoreInline(
        _ preserver: PasteboardPreserver, restoreDelay: Duration, in environment: any InjectionEnvironment
    ) {
        preserver.arm(at: environment.now)
        if let deadline = preserver.deadline(restoreDelay: restoreDelay) { environment.sleep(until: deadline) }
        _ = preserver.restoreIfDue(now: environment.now, restoreDelay: restoreDelay)
    }
}
