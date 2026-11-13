// SPDX-License-Identifier: GPL-3.0-or-later
//
// The worker as the strategies' `InjectionEnvironment` and `StrategyHost`, plus the work it does on deadlines:
// clipboard restore (PLT-R461 steps 4-6) and deferred readback for `verifyAfterEdit` (PLT-R410, PLT-R422).

internal import AppModel
internal import Diagnostics
internal import RealtimeSupport

extension WorkerCore: InjectionEnvironment {
    var now: MonotonicInstant { services.clock.now() }

    /// PLT-R409: absolute deadlines on the inject thread only.
    func sleep(until deadline: MonotonicInstant) { services.clock.sleep(until: deadline) }

    /// Fresh marker sequence per event (PLT-R321). Once posting is broken nothing more is posted (ADR 0311):
    /// the call fails like an event-creation failure, so strategies stop and the worker counts the loss.
    func post(_ event: SyntheticKeyEvent) throws(PostError) -> UInt32 {
        guard !feedback.isPostingBroken else { throw .eventCreationFailed }
        let sequence = nextEventSequence()
        try services.poster.post(event, userData: marker.userData(sequence: sequence, probe: false))
        notePosted(sequence)
        return sequence
    }

    /// Replays the held events queued right behind the running job (paste step 4, split parts). Each is its own
    /// job with its own `finished`; the running job's expectation later covers them (`finish()`).
    func releaseHeldEvents() {
        let running = context
        pullFromRing()
        while let front = backlog.first, front.isHeldEvent {
            _ = backlog.popFirst()
            process(front)
        }
        context = running
    }

    var fieldAccess: any FocusedFieldAccess { axAccess }
    var pasteboard: any PasteboardAccess { services.pasteboard }
}

extension WorkerCore: StrategyHost {
    var pasteboardPreserver: PasteboardPreserver { preserver }

    func pasteCompleted(restoreDelay: TimeSpan) {
        preserver.arm(at: services.clock.now())
        self.restoreDelay = restoreDelay
    }

    /// PLT-R420: counted every time, reported once per focus session (the 256-entry health log stays useful).
    func completionFallback() {
        services.metrics.fallbackActivations.increment()
        if notes.shouldReport(.completionFallback) { recordHealth(.fallbackActivated) }
    }
}

/// `verifyAfterEdit` for key-based strategies (PLT-R410). Key events reach the app asynchronously, so the
/// readback runs `delay` after the job, when the worker is idle, against the absolute range the edit wrote
/// (anchored by the caret read before the job), which later typing at the caret does not move.
struct PendingVerification {
    static let delay: TimeSpan = .milliseconds(50)

    var field: FieldHandle
    var generation: FocusGeneration
    var start: Int
    var expected: [UInt16]
    var strategy: InjectionStrategy
    var fallback: InjectionStrategy
    var placeholderPossible: Bool
    var due: MonotonicInstant
}

extension WorkerCore {
    /// The caret before a key-based job with `verifyAfterEdit` (one bounded AX read, counted as T3).
    func verificationAnchor(for job: EditJob, strategy: InjectionStrategy) -> Injection.TextRange? {
        guard job.plan.parameters.verifyAfterEdit, strategy != .axReplace, let field = job.field,
            case .success(let range) = axAccess.selectedRange(field, timeout: InjectionTiming.axCallTimeout)
        else { return nil }
        return range
    }

    func scheduleVerification(
        of job: EditJob, strategy: InjectionStrategy, anchor: Injection.TextRange?, fallback: InjectionStrategy
    ) {
        guard let anchor, let field = job.field, let lastPosted else { return }
        let mode = job.plan.parameters.inlineCompletion
        pendingVerification = PendingVerification(
            field: field, generation: job.generation, start: anchor.location - job.deleteUTF16Count,
            expected: Array(job.insertion.utf16.prefix(InjectionTiming.maximumAXReadUnits - 2)), strategy: strategy,
            fallback: fallback, placeholderPossible: mode == .placeholder || mode == .axSelectionThenPlaceholder,
            due: MonotonicInstant(
                nanoseconds: lastPosted.at.nanoseconds &+ InjectionTiming.nanoseconds(PendingVerification.delay)))
    }

    /// Restore and readback that are due. Readback waits for an idle worker so no later job changed the field.
    func serviceDeadlines(idle: Bool) {
        let now = services.clock.now()
        if let delay = restoreDelay {
            switch preserver.restoreIfDue(now: now, restoreDelay: delay) {
            case .notDue: break
            case .restored, .nothingPending: restoreDelay = nil
            case .skippedUserCopied:
                restoreDelay = nil
                recordHealth(.pasteRestoreSkipped)
            }
        }
        for _ in 0..<preserver.takeSkippedRestores() { recordHealth(.pasteRestoreSkipped) }
        if idle, let pending = pendingVerification, now >= pending.due {
            pendingVerification = nil
            verify(pending)
        }
    }

    func nextDeadline() -> MonotonicInstant? {
        let restore = restoreDelay.flatMap { preserver.deadline(restoreDelay: $0) }
        switch (restore, pendingVerification?.due) {
        case (let restore?, let verification?): return min(restore, verification)
        case (let restore?, nil): return restore
        case (nil, let verification?): return verification
        case (nil, nil): return nil
        }
    }

    /// Reads one unit before the written range to its end plus one, at most 64 units (PLT-R343). A mismatch
    /// degrades the field to the fallback for the focus session; a leftover placeholder is reported (PLT-R422).
    func verify(_ pending: PendingVerification) {
        guard pending.generation == focusGeneration.load(), pending.start >= 0 else { return }
        let windowStart = max(0, pending.start - 1)
        let offset = pending.start - windowStart
        let range = Injection.TextRange(location: windowStart, length: offset + pending.expected.count + 1)
        guard
            case .success(let text) = services.fieldAccess.text(
                pending.field, in: range, timeout: InjectionTiming.axCallTimeout)
        else { return }
        notes.enter(pending.generation)
        if pending.placeholderPossible, text.unicodeScalars.contains("\u{200B}"),
            notes.shouldReport(.placeholderResidue)
        {
            recordHealth(.placeholderResidue)
        }
        let units = Array(text.utf16)
        let written = units.dropFirst(offset).prefix(pending.expected.count)
        guard Array(written) != pending.expected else { return }
        services.metrics.fallbackActivations.increment()
        notes.degrade(field: pending.field.token, strategy: pending.strategy)
        if notes.shouldReport(.verificationMismatch(pending.strategy)) {
            recordHealth(.fallbackActivated, detail: .fallback(from: pending.strategy, to: pending.fallback))
        }
    }
}

/// Records whether the running job used AX, for the T3 histogram (decide-to-posted with AX).
final class AXUsage: Sendable {
    private let used = Atomic<Bool>(false)
    func mark() { used.store(true, ordering: .relaxed) }
    func reset() { used.store(false, ordering: .relaxed) }
    var wasUsed: Bool { used.load(ordering: .relaxed) }
}

struct InstrumentedFieldAccess: FocusedFieldAccess {
    let base: any FocusedFieldAccess
    /// PLT-R802: one `axCall` interval per AX call.
    let signposts: PlatformSignposts?
    let usage = AXUsage()

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        call { base.selectedRange(field, timeout: timeout) }
    }

    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        call { base.text(field, in: range, timeout: timeout) }
    }

    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan)
        -> AXCallResult<Void>
    {
        call { base.setSelectedRange(field, to: range, timeout: timeout) }
    }

    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        call { base.setSelectedText(field, to: text, timeout: timeout) }
    }

    private func call<Result>(_ body: () -> Result) -> Result {
        usage.mark()
        let signpost = signposts?.begin(.axCall)
        defer { if let signpost { signposts?.end(.axCall, signpost) } }
        return body()
    }
}
