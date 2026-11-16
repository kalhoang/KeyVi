// SPDX-License-Identifier: GPL-3.0-or-later
//
// `backspaceReplace` (4.2), `selectReplace` (4.4) and inline-completion handling (4.3, PLT-R420-R423), plus the
// executor table.

internal import AppModel
internal import RealtimeSupport

/// Worker services a strategy may need beyond `InjectionEnvironment`. The worker's environment conforms; a
/// foreign environment (strategy tests) does not, and strategies degrade gracefully without it.
protocol StrategyHost: AnyObject {
    /// The worker's long-lived preserver, so consecutive pastes coalesce (PLT-R461 step 6).
    var pasteboardPreserver: PasteboardPreserver { get }
    /// Command+V was posted: the worker restores the clipboard after `restoreDelay` (PLT-R461 steps 4-5).
    func pasteCompleted(restoreDelay: TimeSpan)
    /// PLT-R420, PLT-R423: AX could not answer and the next completion option was used.
    func completionFallback()
    /// PLT-R420, PLT-R423, PLT-R904A: what the completion read found and how long it took (timeouts included; nil
    /// when the job had no field to read), and for `forwardDeleteKept` where the kept answer came from, for the dev
    /// recorder's job line.
    func noteCompletionRead(_ read: CompletionRead, duration: TimeSpan?, kept: CaretAtEndMemory.Kept?)
    /// PLT-R423 caret continuity (amendment of 16/11/2026): the live `JobQueue.caretEpoch`.
    var caretEpoch: UInt64 { get }
    /// A `forwardDelete` read for `job` found the caret at the end of the text (`CaretAtEndMemory.remember`).
    func rememberCaretAtEnd(for job: EditJob, epochBeforeRead: UInt64)
    /// The read for `job` did not answer: the remembered answer if it still holds (`CaretAtEndMemory.keep`).
    func keptCaretAtEnd(for job: EditJob) -> CaretAtEndMemory.Kept?
    /// A read found a selection or the caret before the end.
    func forgetCaretAtEnd()
}

/// The AX read of `axSelection`, `axSelectionThenPlaceholder` (PLT-R420) and `forwardDelete` (PLT-R423). Recorded on
/// the dev trace's job line since the retest of 15/11/2026 (Spotlight on macOS 27.2 lost one deletion per edit, and the
/// trace could not tell whether AX reported no selection or did not answer), with the read's duration since the retest
/// of 16/11/2026 (Spotlight answered just after the 15 ms bound while it was opening).
enum CompletionRead {
    /// A selection after the caret: one extra deletion removes it.
    case selected
    /// AX answered with an empty selection (`axSelection`).
    case none
    /// AX timed out or was unavailable (`axSelection`); nothing is added.
    case unreadable
    /// AX timed out or was unavailable (`axSelectionThenPlaceholder`); the placeholder handles the suggestion
    /// (PLT-R421). A label of its own since the review of 16/11/2026, so trace-scan reports only the unreadable reads
    /// that can lose a deletion.
    case unreadableThenPlaceholder
    /// `forwardDelete`: the caret is at the end of the text; a Forward Delete goes before each Backspace.
    case forwardDelete
    /// `forwardDelete`: the caret is before the end of the text; nothing is added.
    case forwardDeleteNotAtEnd
    /// `forwardDelete`: AX timed out or was unavailable, or the job has no field; nothing is added.
    case forwardDeleteUnreadable
    /// `forwardDelete`: AX timed out or was unavailable, but an earlier read of this focus session found the caret at
    /// the end and nothing that can move it happened since (caret continuity, amendment of 16/11/2026: Spotlight's
    /// reads took 3.2, 14.6, 27.2 and then more than 50 ms in one session); a Forward Delete goes before each Backspace.
    case forwardDeleteKept

    var label: StaticString {
        switch self {
        case .selected: "selected"
        case .none: "none"
        case .unreadable: "unreadable"
        case .unreadableThenPlaceholder: "unreadable then placeholder"
        case .forwardDelete: "forwardDelete"
        case .forwardDeleteNotAtEnd: "forwardDelete skipped notAtEnd"
        case .forwardDeleteUnreadable: "forwardDelete skipped unreadable"
        case .forwardDeleteKept: "forwardDelete kept"
        }
    }
}

enum BuiltInExecutors {
    static func executor(for strategy: InjectionStrategy, limits: StrategyLimits) -> any StrategyExecutor {
        switch strategy {
        case .backspaceReplace: BackspaceReplaceExecutor(limits: limits)
        case .selectReplace: SelectReplaceExecutor(limits: limits)
        case .axReplace: AXReplaceExecutor()
        case .paste: PasteExecutor(limits: limits)
        case .passThrough: PassThroughExecutor()
        }
    }
}

/// What to do about an inline suggestion before the first deletion (PLT-R420, PLT-R421, PLT-R423).
enum CompletionPrefix: Equatable {
    case none
    /// A suggestion is selected: one extra backspace removes it.
    case extraDeletion
    /// Insert a placeholder (replacing any suggestion), then delete one more grapheme.
    case placeholder
    /// The caret is at the end of the text with nothing selected: a Forward Delete before each deletion step clears a
    /// suggestion shown after the caret, also one the field offers again after a deletion (PLT-R423).
    case forwardDeleteBeforeEachDeletion

    /// Only edits that delete need handling: an insertion replaces a selected suggestion like typing does.
    static func resolve(for job: EditJob, in environment: any InjectionEnvironment) -> CompletionPrefix {
        let mode = job.plan.parameters.inlineCompletion
        guard job.deleteCount > 0 else { return .none }
        switch mode {
        case .none: return .none
        case .placeholder: return .placeholder
        case .forwardDelete: return forwardDelete(for: job, in: environment)
        case .axSelection, .axSelectionThenPlaceholder: return axSelection(for: job, mode: mode, in: environment)
        }
    }

    /// PLT-R420: one read of the selection, bounded by `axSelectionTimeout` (15 ms). A selection gets one extra
    /// deletion; an unreadable field takes the next option of the value and counts the health event.
    private static func axSelection(
        for job: EditJob, mode: InlineCompletionMode, in environment: any InjectionEnvironment
    ) -> CompletionPrefix {
        let host = environment as? any StrategyHost
        let read = job.field.map { field in
            timed(environment) {
                environment.fieldAccess.selectedRange(field, timeout: InjectionTiming.axSelectionTimeout)
            }
        }
        if let read, case .success(let range) = read.result {
            host?.noteCompletionRead(range.length > 0 ? .selected : .none, duration: read.duration, kept: nil)
            return range.length > 0 ? .extraDeletion : .none
        }
        let fallsBack = mode == .axSelectionThenPlaceholder
        host?.noteCompletionRead(
            fallsBack ? .unreadableThenPlaceholder : .unreadable, duration: read?.duration, kept: nil)
        host?.completionFallback()
        return fallsBack ? .placeholder : .none
    }

    /// PLT-R423: one read of the selection and the character count, bounded by its own `forwardDeleteReadTimeout`
    /// (50 ms; Spotlight answered in 16 to 21 ms while it was opening, retest of 16/11/2026). A selection keeps
    /// PLT-R420's extra deletion; only an empty selection at the end of the text gets Forward Delete, because anywhere
    /// else it would delete the character after the caret. A caret before the end is normal editing. A read that does
    /// not answer keeps an earlier answer of "at the end" while the caret's continuity holds (amendment of 16/11/2026:
    /// in one Spotlight session the reads took 3.2, 14.6, 27.2 and then more than 50 ms); without one, nothing is added
    /// and the PLT-R420 health event is counted. A fresh answer always wins and replaces the remembered one.
    private static func forwardDelete(for job: EditJob, in environment: any InjectionEnvironment) -> CompletionPrefix {
        let host = environment as? any StrategyHost
        let epochBeforeRead = host?.caretEpoch
        let read = job.field.map { field in
            timed(environment) {
                environment.fieldAccess.caret(field, timeout: InjectionTiming.forwardDeleteReadTimeout)
            }
        }
        guard let read, case .success(let caret) = read.result else {
            return unanswered(job, duration: read?.duration, host: host)
        }
        guard caret.isAtEndOfText else {
            host?.forgetCaretAtEnd()
            let selected = caret.selection.length > 0
            host?.noteCompletionRead(selected ? .selected : .forwardDeleteNotAtEnd, duration: read.duration, kept: nil)
            return selected ? .extraDeletion : .none
        }
        if let epochBeforeRead { host?.rememberCaretAtEnd(for: job, epochBeforeRead: epochBeforeRead) }
        host?.noteCompletionRead(.forwardDelete, duration: read.duration, kept: nil)
        return .forwardDeleteBeforeEachDeletion
    }

    /// PLT-R423: the read timed out, AX was unavailable or the job has no field. The caret's continuity since an
    /// earlier answer of "at the end" keeps the Forward Delete; otherwise the caret is unknown, so nothing is added
    /// (PLT-R407) and the PLT-R420 health event is counted.
    private static func unanswered(
        _ job: EditJob, duration: TimeSpan?, host: (any StrategyHost)?
    ) -> CompletionPrefix {
        if let kept = host?.keptCaretAtEnd(for: job) {
            host?.noteCompletionRead(.forwardDeleteKept, duration: duration, kept: kept)
            return .forwardDeleteBeforeEachDeletion
        }
        host?.noteCompletionRead(.forwardDeleteUnreadable, duration: duration, kept: nil)
        host?.completionFallback()
        return .none
    }

    /// One completion read and how long it took on the worker's clock, for the dev recorder (PLT-R904A).
    private static func timed<Value: Sendable>(
        _ environment: any InjectionEnvironment, _ read: () -> AXCallResult<Value>
    ) -> (result: AXCallResult<Value>, duration: TimeSpan) {
        let started = environment.now
        let result = read()
        return (result, environment.now.duration(since: started))
    }

    static func placeholderEvent(for job: EditJob) -> SyntheticKeyEvent {
        guard let chunk = InlineUTF16(InjectionTiming.placeholder) else { preconditionFailure("placeholder") }
        return SyntheticKeys.unicode(chunk, keyCode: SyntheticKeys.unicodeKeyCode(for: job))
    }
}

/// 4.2: `deleteCount` backspace pairs, then the insertion as Unicode events.
struct BackspaceReplaceExecutor: StrategyExecutor {
    let limits: StrategyLimits
    var strategy: InjectionStrategy { .backspaceReplace }

    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome {
        var script = KeyScript()
        var deletions = job.deleteCount
        var clearsBeforeEachDeletion = false
        switch CompletionPrefix.resolve(for: job, in: environment) {
        case .none: break
        case .extraDeletion: deletions += 1
        case .placeholder:
            script.append(CompletionPrefix.placeholderEvent(for: job), phase: .prefix)
            deletions += 1
        case .forwardDeleteBeforeEachDeletion: clearsBeforeEachDeletion = true
        }
        for _ in 0..<deletions {
            // PLT-R423: the field may offer its suggestion again after each deletion.
            if clearsBeforeEachDeletion { script.append(SyntheticKeys.forwardDelete, phase: .delete) }
            script.append(SyntheticKeys.backspace, phase: .delete)
        }
        script.appendInsertion(of: job)
        return ScriptRunner.run(script, job: job, limits: limits, in: environment)
    }
}

/// 4.4: `deleteCount` Shift+Left presses, then the insertion replaces the selection.
struct SelectReplaceExecutor: StrategyExecutor {
    let limits: StrategyLimits
    var strategy: InjectionStrategy { .selectReplace }

    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome {
        var script = KeyScript()
        var selections = job.deleteCount
        switch CompletionPrefix.resolve(for: job, in: environment) {
        case .none: break
        case .extraDeletion:
            // Shift+Left cannot remove a suggestion selected after the caret; one backspace does.
            script.append(SyntheticKeys.backspace, phase: .delete)
        case .placeholder:
            script.append(CompletionPrefix.placeholderEvent(for: job), phase: .prefix)
            selections += 1
        case .forwardDeleteBeforeEachDeletion:
            // PLT-R423: Shift+Left deletes nothing, so the field offers no new suggestion between the steps.
            script.append(SyntheticKeys.forwardDelete, phase: .delete)
        }
        script.append(SyntheticKeys.shiftLeft, phase: .delete, count: selections)
        if job.insertion.isEmpty, selections > 0 {
            // A pure deletion: typing nothing would leave the selection in place.
            script.append(SyntheticKeys.backspace, phase: .delete)
        }
        script.appendInsertion(of: job)
        return ScriptRunner.run(script, job: job, limits: limits, in: environment)
    }
}

/// `passThrough` jobs are never built (4.7); the worker replays the trigger itself. This executor posts
/// nothing and reports a failure so a misuse falls through to the next strategy.
struct PassThroughExecutor: StrategyExecutor {
    var strategy: InjectionStrategy { .passThrough }

    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome {
        .failedBeforePosting(.postingFailed)
    }
}
