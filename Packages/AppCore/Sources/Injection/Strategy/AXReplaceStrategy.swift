// SPDX-License-Identifier: GPL-3.0-or-later
//
// `axReplace` (4.5): select the composition range ending at the caret, replace the selection, then a mandatory
// bounded readback. Never replaces the whole `AXValue`; posts no key events.

internal import AppModel
internal import RealtimeSupport

struct AXReplaceExecutor: StrategyExecutor {
    var strategy: InjectionStrategy { .axReplace }

    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome {
        guard let field = job.field else { return .failedBeforePosting(.axUnavailable) }
        let access = environment.fieldAccess
        let timeout = InjectionTiming.axCallTimeout
        let selection: Injection.TextRange
        switch access.selectedRange(field, timeout: timeout) {
        case .success(let range): selection = range
        case let failure: return .failedBeforePosting(Self.reason(failure, write: false))
        }
        let start = selection.location - job.deleteUTF16Count
        // Nothing was written and the field's AX works: a per-job failure that keeps `axReplace` for the field
        // (4.5 reserves the session fallback for errors and mismatches after the write).
        guard start >= 0 else { return .failedBeforePosting(.historyMismatch) }
        // A selected suggestion after the caret is replaced together with the composition, like typing does.
        let target = Injection.TextRange(location: start, length: job.deleteUTF16Count + selection.length)
        let selected = access.setSelectedRange(field, to: target, timeout: timeout)
        guard selected.isSuccess else { return .failedBeforePosting(Self.reason(selected, write: true)) }
        let written = access.setSelectedText(field, to: job.insertion, timeout: timeout)
        guard written.isSuccess else {
            // Put the caret back so a key-based fallback does not delete the selected range plus more.
            let restored = access.setSelectedRange(field, to: selection, timeout: timeout).isSuccess
            let reason = Self.reason(written, write: true)
            return restored ? .failedBeforePosting(reason) : .failedAfterPosting(reason)
        }
        guard Self.readBack(job, field: field, start: start, access: access) else {
            return Self.mismatch(field: field, target: target, caret: selection, access: access)
        }
        return .completed(lastEventSequence: 0)
    }

    /// Mandatory readback (4.5), at most 64 UTF-16 units (PLT-R343). On success `execute` reports `completed`
    /// without an event sequence: `axReplace` posts nothing and the worker settles the job immediately.
    static func readBack(_ job: EditJob, field: FieldHandle, start: Int, access: any FocusedFieldAccess) -> Bool {
        let expected = Array(job.insertion.utf16.prefix(InjectionTiming.maximumAXReadUnits))
        let range = Injection.TextRange(location: start, length: expected.count)
        guard case .success(let text) = access.text(field, in: range, timeout: InjectionTiming.axCallTimeout)
        else { return false }
        return Array(text.utf16) == expected
    }

    /// 4.5 "writes may silently do nothing": when the composition range is still selected the text write was
    /// ignored, so nothing changed. Put the caret back (the next key would otherwise replace the selected word)
    /// and report a failure before posting: the fallback strategy delivers the edit, the trigger is not lost
    /// (PLT-R312) and the field still uses the fallback for the rest of the focus session. A moved selection
    /// means something was written: the fallback must not apply the edit a second time.
    static func mismatch(
        field: FieldHandle, target: Injection.TextRange, caret: Injection.TextRange, access: any FocusedFieldAccess
    ) -> StrategyOutcome {
        let timeout = InjectionTiming.axCallTimeout
        guard case .success(let now) = access.selectedRange(field, timeout: timeout), now == target else {
            return .failedAfterPosting(.readbackMismatch)
        }
        let restored = access.setSelectedRange(field, to: caret, timeout: timeout).isSuccess
        return restored ? .failedBeforePosting(.readbackMismatch) : .failedAfterPosting(.readbackMismatch)
    }

    static func reason<Value>(_ result: AXCallResult<Value>, write: Bool) -> FallbackReason {
        switch result {
        case .timedOut: .axTimedOut
        case .success, .unavailable: write ? .axWriteFailed : .axUnavailable
        case .failed: write ? .axWriteFailed : .axUnavailable
        }
    }
}

extension AXCallResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
