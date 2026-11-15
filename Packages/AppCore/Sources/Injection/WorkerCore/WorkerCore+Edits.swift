// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit jobs: posting-broken loss, generation discard (PLT-R316), preparation (PLT-R402, PLT-R403, PLT-R480),
// re-entry verification (PLT-R342) and the strategy chain with detectable-failure fallbacks (PLT-R410, 4.5).

internal import AppModel
internal import Diagnostics
internal import Foundation
internal import RealtimeSupport

extension WorkerCore {
    func processEdit(_ job: EditJob) {
        begin(job.sequence)
        runningEdit = job.sequence
        // A new edit changes the text a pending readback would check.
        pendingVerification = nil
        axAccess.usage.reset()
        let outcome = editOutcome(job)
        runningEdit = nil
        finishEdit(job, outcome: outcome)
    }

    func finishEdit(_ job: EditJob, outcome: JobOutcome) {
        #if DEV_RECORDER
        recordDevJob(job, outcome: outcome)  // PLT-R904A
        #endif
        // PLT-R357: a revision that was not applied as computed leaves the engine's history unlike the screen.
        if job.kind == .revision, outcome != .executed { feedback.requestCompositionReset() }
        feedback.record(outcome, for: job.sequence)
        outcomes.record(outcome, for: job.sequence)
        if outcome.deliveredEdit {
            if job.kind == .macro { lastMacroFinishedAt = services.clock.now() }
            recordLatency(of: job, outcome: outcome)
        }
        finish()
    }

    private func editOutcome(_ job: EditJob) -> JobOutcome {
        if feedback.isPostingBroken {
            // ADR 0311: nothing is posted; the trigger is counted, never silently dropped.
            if job.trigger != nil { countLoss() }
            feedback.requestCompositionReset()
            return .abandoned
        }
        if job.generation < focusGeneration.load() {
            // PLT-R316 + ADR 0308: an edit computed for another field is never applied; its key is replayed.
            replayTrigger(of: job)
            feedback.requestCompositionReset()
            unreportedDiscards += 1
            return .discardedForGeneration
        }
        // PLT-R340 amendment: a kept late focus change is confirmed before anything is posted, also for a job
        // without an edit (the check of a key that only passes).
        if !lateFocusMatches(job) { return passThrough(job) }
        if job.kind == .revision { return revisionOutcome(job) }
        let prepared = prepare(job)
        if prepared.deleteCount == 0, prepared.insertion.isEmpty { return .executed }
        if !reentryMatches(prepared) { return passThrough(prepared) }
        return runChain(prepared)
    }

    /// PLT-R357: a revision touches the previous token, so PLT-R342 applies as for re-entry. Where the rule verifies
    /// (`verifyBeforeApply`), the text before the caret must end with the previous token, one space and the current
    /// display (an unreadable field applies, as `whenReadable` says). On a mismatch, or when the pipeline did not
    /// know the previous token, only the current token's part is applied and the engine is reset.
    func revisionOutcome(_ job: EditJob) -> JobOutcome {
        let expected = job.revision?.expectedText
        if let expected, job.deleteCount <= expected.count, revisionTextMatches(job, expected: expected) {
            var full = job
            full.replacedText = expected
            let prepared = prepare(full)
            if prepared.deleteCount == 0, prepared.insertion.isEmpty { return .executed }
            return runChain(prepared)
        }
        if expected == nil, !job.verifyBeforeApply { return runChain(prepare(job)) }
        feedback.requestCompositionReset()
        guard let revision = job.revision else { return .executedWithFallback }
        let part = revision.currentPart(deleteCount: job.deleteCount, insert: job.insertion)
        var partial = job
        partial.deleteCount = part.delete.count
        partial.deleteUTF16Count = part.delete.utf16.count
        partial.insertion = part.insert
        partial.replacedText = part.delete
        let prepared = prepare(partial)
        if prepared.deleteCount == 0, prepared.insertion.isEmpty { return .executedWithFallback }
        let outcome = runChain(prepared)
        return outcome == .executed ? .executedWithFallback : outcome
    }

    private func revisionTextMatches(_ job: EditJob, expected: String) -> Bool {
        guard job.verifyBeforeApply, let field = job.field else { return true }
        return textBeforeCaret(of: field, endsWith: expected, allowingSelection: false, atTokenStart: false) ?? true
    }

    /// PLT-R403 NFC, PLT-R480 4,000-grapheme cap, PLT-R402 prefix trim, PLT-R408 first-edit delay.
    func prepare(_ job: EditJob) -> EditJob {
        var prepared = job
        var insertion = job.insertion.precomposedStringWithCanonicalMapping
        if insertion.count > configuration.maximumExpansionGraphemes {
            insertion = String(insertion.prefix(configuration.maximumExpansionGraphemes))
        }
        let edit = MinimalEdit(
            deleteCount: job.deleteCount, deleteUTF16Count: job.deleteUTF16Count, replaced: job.replacedText,
            insertion: insertion)
        prepared.deleteCount = edit.deleteCount
        prepared.deleteUTF16Count = edit.deleteUTF16Count
        prepared.insertion = edit.insertion
        prepared.wordStartedNearFocusChange = firstEdit.applies(to: job)
        return prepared
    }

    /// PLT-R342: read at most 64 UTF-16 units before the caret and compare with the expected word. Unreadable
    /// fields apply the edit (`verifyReentry: whenReadable`); a mismatch drops the history and passes the key.
    /// The flag decides, whatever the kind: the pipeline sets it for every edit of a word re-opened by Backspace,
    /// macros and restores included. A restore that fails the check delivers nothing (it has no trigger).
    func reentryMatches(_ job: EditJob) -> Bool {
        guard job.verifyBeforeApply, let expected = job.replacedText, !expected.isEmpty, let field = job.field
        else { return true }
        return textBeforeCaret(of: field, endsWith: expected, allowingSelection: false, atTokenStart: false) ?? true
    }

    /// PLT-R340 amendment (2026-11-14): after a focus change the tap discovered late and kept the composition, the
    /// new element must be readable and its text before the caret must end with the token's display. A selected
    /// inline completion after the caret is allowed (the text before the selection is compared). The token begins
    /// at the start of the text or after a separator, so the unit before it is read in the same bounded read: text
    /// that merely ends with the token ("Nova" for "a") is not the word being typed. Strict: an unreadable field, no
    /// field and no expected text all fail, which turns the kept composition into the hard boundary it would have
    /// been.
    func lateFocusMatches(_ job: EditJob) -> Bool {
        guard job.verifyLateFocus else { return true }
        guard let expected = job.replacedText, !expected.isEmpty, let field = job.field else { return false }
        return textBeforeCaret(of: field, endsWith: expected, allowingSelection: true, atTokenStart: true) ?? false
    }

    /// Bounded read (PLT-R343): the selected range, then at most 64 UTF-16 units before its start. Nil when the
    /// field cannot be read, or when it has a selection and `allowingSelection` is false (no caret to compare at).
    /// `atTokenStart`: the unit before the expected text, when it fits in the bound, must be a separator.
    private func textBeforeCaret(
        of field: FieldHandle, endsWith expected: String, allowingSelection: Bool, atTokenStart: Bool
    ) -> Bool? {
        let timeout = InjectionTiming.axCallTimeout
        guard case .success(let selection) = axAccess.selectedRange(field, timeout: timeout),
            allowingSelection || selection.length == 0
        else { return nil }
        let bound = InjectionTiming.maximumAXReadUnits
        let expectedUnits = Array(expected.utf16.suffix(bound))
        guard selection.location >= expectedUnits.count else { return false }
        let checksStart = atTokenStart && expectedUnits.count < bound && selection.location > expectedUnits.count
        let length = expectedUnits.count + (checksStart ? 1 : 0)
        let range = Injection.TextRange(location: selection.location - length, length: length)
        guard case .success(let text) = axAccess.text(field, in: range, timeout: timeout) else { return nil }
        let units = Array(text.utf16)
        guard units.count == length else { return false }
        if checksStart, !Self.separatesTokens(units[0]) { return false }
        return Array(units.suffix(expectedUnits.count)) == expectedUnits
    }

    /// Whitespace, punctuation, symbols and controls end a token; letters, marks and digits do not. A surrogate
    /// half belongs to a supplementary character (emoji and other symbols), which counts as a separator.
    static func separatesTokens(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark,
            .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return false
        default:
            return true
        }
    }

    /// Strategy, then fallbacks, for detectable failures only (PLT-R410, 4.5). `passThrough` replays the trigger.
    func runChain(_ job: EditJob) -> JobOutcome {
        let chain = strategyChain(for: job)
        for (index, strategy) in chain.enumerated() {
            if strategy == .passThrough || feedback.isPostingBroken { return passThrough(job) }
            let next = index + 1 < chain.count ? chain[index + 1] : .passThrough
            let anchor = verificationAnchor(for: job, strategy: strategy)
            let outcome = executors[strategy, default: PassThroughExecutor()].execute(job, in: self)
            if let broken = postingBrokenOutcome(job, outcome) { return broken }
            switch outcome {
            case .completed:
                scheduleVerification(of: job, strategy: strategy, anchor: anchor, fallback: next)
                return index == 0 ? .executed : .executedWithFallback
            case .failedBeforePosting(let reason):
                noteFallback(job, from: strategy, to: next, reason: reason)
            case .failedAfterPosting(let reason):
                noteFallback(job, from: strategy, to: next, reason: reason)
                feedback.requestCompositionReset()
                return .executedWithFallback
            }
        }
        return passThrough(job)
    }

    /// ADR 0311: posting broke while the script was posting. That is the posting-broken path, not a fallback: the
    /// undelivered edit (or its trigger, if nothing was posted) is a counted loss, no fallback event is recorded.
    private func postingBrokenOutcome(_ job: EditJob, _ outcome: StrategyOutcome) -> JobOutcome? {
        guard feedback.isPostingBroken else { return nil }
        let postedSomething: Bool
        switch outcome {
        case .failedBeforePosting(.postingFailed): postedSomething = false
        case .failedAfterPosting(.postingFailed): postedSomething = true
        default: return nil
        }
        if postedSomething || job.trigger != nil { countLoss() }
        feedback.requestCompositionReset()
        return postedSomething ? .executedWithFallback : .abandoned
    }

    /// The key passes through instead of the edit: replay the trigger, reset the composition.
    func passThrough(_ job: EditJob) -> JobOutcome {
        replayTrigger(of: job)
        feedback.requestCompositionReset()
        return .passedThroughByFallback
    }

    /// PLT-R460/R480: `paste` only when opted in, first for long text; strategies degraded for this field in this
    /// focus session are skipped (4.5).
    func strategyChain(for job: EditJob) -> [InjectionStrategy] {
        var chain = [job.plan.strategy] + job.plan.fallback
        let parameters = job.plan.parameters
        if parameters.pasteOptedIn {
            if job.insertion.count > configuration.pasteThresholdGraphemes { chain.insert(.paste, at: 0) }
        } else {
            chain.removeAll { $0 == .paste }
        }
        notes.enter(job.generation)
        let degraded = notes.degradedStrategies(field: job.field?.token)
        var seen = Set<InjectionStrategy>()
        return chain.filter { !degraded.contains($0) && seen.insert($0).inserted }
    }

    func noteFallback(_ job: EditJob, from: InjectionStrategy, to: InjectionStrategy, reason: FallbackReason) {
        #if DEV_RECORDER
        recordDevFallback(job, from: from, to: to, reason: reason)  // PLT-R904A
        #endif
        services.metrics.fallbackActivations.increment()
        notes.enter(job.generation)
        if reason.degradesSession { notes.degrade(field: job.field?.token, strategy: from) }
        if notes.shouldReport(.fallback(from, reason)) {
            recordHealth(.fallbackActivated, detail: .fallback(from: from, to: to))
        }
    }

    /// T2 / T3 / probe T2 (02-platform.md 8.1), and the capture record (PLT-R905).
    private func recordLatency(of job: EditJob, outcome: JobOutcome) {
        let posted = context?.posted == true
        let usedAX = axAccess.usage.wasUsed
        guard posted || usedAX else { return }
        let end = posted ? (lastPosted?.at ?? services.clock.now()) : services.clock.now()
        let elapsed = end.nanoseconds(since: job.createdAt)
        let metrics = services.metrics
        let histogram =
            job.isProbe ? metrics.probeDecideToPosted : usedAX ? metrics.decideToPostedWithAX : metrics.decideToPosted
        histogram.record(nanoseconds: elapsed)
        if let capture = services.capture, capture.isRecording {
            _ = capture.injectRecords.push(
                .job(
                    sequence: job.sequence.rawValue, strategy: job.plan.strategy,
                    durationMicroseconds: elapsed / 1_000, outcome: outcome.captureLabel))
        }
    }
}

extension FallbackReason {
    /// AX failures and readback mismatches mean "this field mishandles the strategy": use the fallback for the
    /// rest of the focus session (4.5). Pasteboard state, posting, job length and history mismatches are per job.
    var degradesSession: Bool {
        switch self {
        case .axUnavailable, .axTimedOut, .axWriteFailed, .readbackMismatch: true
        case .pasteboardUnsafe, .postingFailed, .jobTooLong, .historyMismatch: false
        }
    }
}

/// Per focus session: strategies degraded per field, and health events already reported (one per kind and
/// reason, so a field that always fails does not flood the 256-entry health log).
struct SessionNotes {
    enum Note: Hashable {
        case fallback(InjectionStrategy, FallbackReason)
        case completionFallback
        case verificationMismatch(InjectionStrategy)
        case placeholderResidue
    }

    private struct Degraded: Hashable {
        var field: UInt64?
        var strategy: InjectionStrategy
    }

    private var generation: FocusGeneration?
    private var degraded: Set<Degraded> = []
    private var reported: Set<Note> = []

    mutating func enter(_ generation: FocusGeneration) {
        guard generation != self.generation else { return }
        self.generation = generation
        degraded.removeAll()
        reported.removeAll()
    }

    mutating func degrade(field: UInt64?, strategy: InjectionStrategy) {
        degraded.insert(Degraded(field: field, strategy: strategy))
    }

    func degradedStrategies(field: UInt64?) -> Set<InjectionStrategy> {
        Set(degraded.filter { $0.field == field }.map(\.strategy))
    }

    mutating func shouldReport(_ note: Note) -> Bool { reported.insert(note).inserted }
}
