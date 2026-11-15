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
    /// PLT-R420, PLT-R423, PLT-R904A: what the completion read found, for the dev recorder's job line.
    func noteCompletionRead(_ read: CompletionRead)
}

/// The AX read of `axSelection`, `axSelectionThenPlaceholder` (PLT-R420) and `forwardDelete` (PLT-R423). Recorded on
/// the dev trace's job line since the retest of 15/11/2026 (Spotlight on macOS 27.2 lost one deletion per edit, and the
/// trace could not tell whether AX reported no selection or did not answer).
enum CompletionRead {
    /// A selection after the caret: one extra deletion removes it.
    case selected
    /// AX answered with an empty selection (`axSelection`).
    case none
    /// AX timed out or was unavailable (`axSelection`).
    case unreadable
    /// `forwardDelete`: the caret is at the end of the text; a Forward Delete goes before each Backspace.
    case forwardDelete
    /// `forwardDelete`: the caret is before the end of the text; nothing is added.
    case forwardDeleteNotAtEnd
    /// `forwardDelete`: AX timed out or was unavailable, or the job has no field; nothing is added.
    case forwardDeleteUnreadable

    var label: StaticString {
        switch self {
        case .selected: "selected"
        case .none: "none"
        case .unreadable: "unreadable"
        case .forwardDelete: "forwardDelete"
        case .forwardDeleteNotAtEnd: "forwardDelete skipped notAtEnd"
        case .forwardDeleteUnreadable: "forwardDelete skipped unreadable"
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
        case .axSelection, .axSelectionThenPlaceholder:
            let host = environment as? any StrategyHost
            if let field = job.field,
                case .success(let range) = environment.fieldAccess.selectedRange(
                    field, timeout: InjectionTiming.axSelectionTimeout)
            {
                host?.noteCompletionRead(range.length > 0 ? .selected : .none)
                return range.length > 0 ? .extraDeletion : .none
            }
            host?.noteCompletionRead(.unreadable)
            host?.completionFallback()
            return mode == .axSelectionThenPlaceholder ? .placeholder : .none
        }
    }

    /// PLT-R423: one bounded read of the selection and the character count. A selection keeps PLT-R420's extra
    /// deletion; only an empty selection at the end of the text gets Forward Delete, because anywhere else it would
    /// delete the character after the caret. A caret before the end is normal editing; an unreadable field counts the
    /// PLT-R420 health event.
    private static func forwardDelete(for job: EditJob, in environment: any InjectionEnvironment) -> CompletionPrefix {
        let host = environment as? any StrategyHost
        guard let field = job.field,
            case .success(let caret) = environment.fieldAccess.caret(field, timeout: InjectionTiming.axSelectionTimeout)
        else {
            host?.noteCompletionRead(.forwardDeleteUnreadable)
            host?.completionFallback()
            return .none
        }
        if caret.selection.length > 0 {
            host?.noteCompletionRead(.selected)
            return .extraDeletion
        }
        guard caret.isAtEndOfText else {
            host?.noteCompletionRead(.forwardDeleteNotAtEnd)
            return .none
        }
        host?.noteCompletionRead(.forwardDelete)
        return .forwardDeleteBeforeEachDeletion
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
