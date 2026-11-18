// SPDX-License-Identifier: GPL-3.0-or-later
//
// The late focus change of PLT-R340 (amendments of 14/11, 15/11 and 19/11/2026): what a new focus snapshot means for
// the word being typed. Tap-safe: integer and flag tests on values the pipeline holds, one ring push per judged
// change while a word is active; no AX, I/O, lock or allocation (PLT-R304, PLT-R305). The records carry integers and
// a reason code only (PLT-R901).

internal import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport

/// PLT-R340 amendment (product owner, 2026-11-14, T5.5): a focus change the tap discovers after keys of the active
/// token were composed with the previous snapshot keeps the composition when the new element belongs to the same
/// process and the change was observed at most `windowNanoseconds` after the token's last key and, when the previous
/// snapshot named an element of that process, also after its first key (amendment of 19/11/2026). The first job
/// after the discovery verifies the new element's text before the caret (`EditJob.verifyLateFocus`).
enum LateFocusChange {
    /// 500 ms: the ax thread observes a focus change that the typing caused (a sheet or an editor taking the key it
    /// was opened by) or that the app reported late within its settle window (last re-read 400 ms after the
    /// notification, `FocusSettle.delays`, PLT-R380) plus scheduling slack; it equals the PLT-R382 typing-pause
    /// threshold, beyond which a key no longer belongs to continuous typing. A change observed later is not part of
    /// the word and stays a hard boundary. Also measured from the word's first key when the previous snapshot named
    /// an element of the same process: it really changed at most this long before `changedAt`, so a word that began
    /// earlier went into the previous element (VM run of 19/11/2026, `testhost.native.textView`: the previous field's
    /// unfinished word was kept, its check failed and the reset landed mid-word). Not from the first key when the
    /// word began at most this long after a focus-moving trigger (PLT-R389) that the tap saw after the previous
    /// element was observed: the trigger is the known cause of the change (VM runs of 19/11/2026 at 28aaa256).
    static let windowNanoseconds: UInt64 = 500_000_000
}

/// What a new focus generation means for the word being typed (`KeyPipeline.judgeFocusChange`).
enum FocusChangeVerdict: Equatable {
    /// The element the word is in, by its field token: no focus change. A decision unlike `decision` (the one last
    /// resolved for that element) is still a boundary (PLT-R340).
    case sameElement(decision: FocusIdentity.Decision)
    /// The word goes on; `checked`: the first job verifies the new element (a readable one).
    case kept(checked: Bool)
    case boundary

    var keepsWord: Bool { self != .boundary }
}

extension KeyPipeline {
    /// PLT-R340 amendment: keep the composition across a focus change discovered after keys of the active token
    /// were composed with the previous snapshot. Same process (or a previous snapshot that names no process because
    /// its system-wide focus read timed out, amendment of 2026-11-15: Pa's Safari trace), an element the worker can
    /// read (a field handle and AX available), no focus pause, the same engine variant (or one the engine can
    /// continue into, `engineCanContinue`), and the change observed at most `LateFocusChange.windowNanoseconds` after
    /// the token's last key. Everything else stays a hard boundary.
    ///
    /// Amendment of 19/11/2026: when the previous snapshot named an element of the same process, the change must also
    /// be observed within the window of the word's first key, because that element really changed then and a word
    /// begun earlier was typed into the previous one. A word re-opened by Backspace keeps the time of the first key
    /// typed since the display was last empty, and a word whose start is unknown is refused. Without a previous
    /// element (a timed-out read, the PLT-R381 frontmost fallback, an element read that failed) the last-key window
    /// applies alone: no element is known to have changed under the word, and the next real snapshot can come
    /// seconds after its first key.
    ///
    /// Second amendment of 19/11/2026 (VM runs at 28aaa256, integration-suite.md section 10.9), one "last known
    /// element" rule:
    /// - The element the word is in, found again by its token after snapshots without one
    ///   (`ObservedState.lastElement`, or `KeyState.wordReference` while such snapshots kept the word), is no focus
    ///   change: no boundary, no check (`testhost.native.burst`). Its decision is compared with the one last resolved
    ///   for it, since a snapshot without its attributes may have resolved another rule.
    /// - A snapshot of the same process without a readable element (no field handle, or AX timed out or failed) that
    ///   passes the other conditions keeps the word without a check, since the worker cannot read it; the next
    ///   snapshot is judged against the element the word began in (`testhost.sheet.commandS`).
    /// - The first-key window does not apply to a word that began within the window after a focus-moving trigger
    ///   (PLT-R389) the tap saw after the previous element was observed (T5.5 on a slow machine).
    ///
    /// While a word is active, every verdict but a plain same element goes into the tap log with both intervals in
    /// microseconds and the deciding `LateFocusReason` (`lateFocusKept`, `lateFocusRefused`; one ring push, integers
    /// only, PLT-R304, PLT-R901). The active-display read runs only on this rare path.
    func judgeFocusChange(_ focus: FocusSnapshot, identity: FocusIdentity, at now: MonotonicInstant)
        -> FocusChangeVerdict
    {
        let wordActive = engineDirty && keyState.lastComposedKeyAt != nil && !engine.activeDisplay.isEmpty
        if let owner = keyState.wordReference ?? seen.lastElement, owner.names(identity) {
            // Found again after a snapshot without its token, with its decision: worth a record while a word is active.
            if wordActive && seen.focus.fieldToken != identity.fieldToken && identity.decision == owner.decision {
                recordLateFocus(.sameElement, focus, now)
            }
            return .sameElement(decision: owner.decision)
        }
        guard wordActive else { return .boundary }
        let reason = lateFocusReason(
            focus, identity: identity, against: keyState.wordReference ?? FocusReference(seen.focus))
        recordLateFocus(reason, focus, now)
        switch reason {
        case .window, .trigger: return .kept(checked: true)
        case .unreadable: return .kept(checked: false)
        case .sameElement, .otherProcess, .noElement, .axUnavailable, .paused, .variant, .lastKeyWindow,
            .firstKeyWindow:
            return .boundary
        }
    }

    /// The check that decides a change while a word is active, in this order: the process, a readable element where
    /// one is needed, the pause, the variant, the last-key window, then the first-key window.
    private func lateFocusReason(_ focus: FocusSnapshot, identity: FocusIdentity, against reference: FocusReference)
        -> LateFocusReason
    {
        let sameProcess = identity.pid != ToggleOverride.noProcess && identity.pid == reference.pid
        guard identity.pid != ToggleOverride.noProcess, sameProcess || reference.appUnknownAfterTimeout else {
            return .otherProcess
        }
        // Without a readable element the process must be known to be the word's own (no check can confirm it).
        if !identity.readable && !sameProcess { return focus.fieldHandle == nil ? .noElement : .axUnavailable }
        if focus.pause != nil { return .paused }
        let variant = identity.decision.variant
        guard variant == seen.focus.decision.variant || engineCanContinue(into: variant) else { return .variant }
        let window = LateFocusChange.windowNanoseconds
        guard let lastKey = keyState.lastComposedKeyAt, focus.changedAt.nanoseconds(since: lastKey) <= window else {
            return .lastKeyWindow
        }
        let elementChanged = sameProcess && reference.token != nil
        let fitsFirstKey = keyState.wordStartedAt.map { focus.changedAt.nanoseconds(since: $0) <= window } == true
        if elementChanged && !fitsFirstKey {
            guard wordFollowedTrigger(after: reference) else { return .firstKeyWindow }
            if identity.readable { return .trigger }
        }
        return identity.readable ? .window : .unreadable
    }

    /// PLT-R389 trigger before the word: seen after the previous element was observed (otherwise that element may be
    /// the trigger's own change, a sheet's field), and the word's first key followed it within the window.
    private func wordFollowedTrigger(after reference: FocusReference) -> Bool {
        guard let trigger = keyState.lastFocusTriggerAt, let start = keyState.wordStartedAt,
            trigger > reference.changedAt, start >= trigger
        else { return false }
        return start.nanoseconds(since: trigger) <= LateFocusChange.windowNanoseconds
    }

    /// One fixed-size record: microseconds from the word's last and first key to the snapshot's `changedAt` (zero
    /// when it came first, `UInt64.max` for an unknown start) and the reason code.
    private func recordLateFocus(_ reason: LateFocusReason, _ focus: FocusSnapshot, _ now: MonotonicInstant) {
        let sinceLastKey = keyState.lastComposedKeyAt.map { focus.changedAt.nanoseconds(since: $0) / 1_000 } ?? .max
        let sinceWordStart = keyState.wordStartedAt.map { focus.changedAt.nanoseconds(since: $0) / 1_000 } ?? .max
        context.tapLog.push(
            TapLogRecord(
                code: reason.keeps ? .lateFocusKept : .lateFocusRefused, at: now, a: sinceLastKey, b: sinceWordStart,
                detail: reason.rawValue))
    }

    /// After the verdict: the last element with a token, and the element the word began in while snapshots without
    /// a readable element keep it.
    func remember(_ identity: FocusIdentity, verdict: FocusChangeVerdict) {
        if case .kept(checked: false) = verdict {
            // The word began in the previous focus; keep comparing with it if it named an element.
            if keyState.wordReference == nil, seen.focus.fieldToken != nil {
                keyState.wordReference = FocusReference(seen.focus)
            }
        } else {
            keyState.wordReference = nil
        }
        if identity.fieldToken != nil {
            seen.lastElement = FocusReference(identity)
        } else if identity.pid != seen.lastElement?.pid && !identity.appUnknownAfterTimeout {
            seen.lastElement = nil  // another process, or AX answered that no application has the focus
        }
        seen.focus = identity
    }

    /// ENG-R1211 amendment of 19/11/2026 (VM run of 19/11/2026, `testhost.panel.inlineCompletionTwice`): the engine
    /// of `variant` can take over the word being typed when the variants differ only in `lookaheadRevision`, which
    /// decides nothing before a commit (ENG-R829, PLT-R357), the engine has committed nothing since its last reset
    /// (its state is then the active word alone, the same under both switches), and no learned-memory swap waits
    /// (ENG-R865). Integer and flag tests only (PLT-R304).
    func engineCanContinue(into variant: EngineVariant) -> Bool {
        variant.differsOnlyInLookaheadRevision(from: seen.engineVariant) && !keyState.committedSinceEngineReset
            && !seen.memorySwapPending
    }

    /// The key that discovered a kept late focus change produced no edit to verify: a job without an edit carries
    /// the check (the key itself is then held behind it as a replay, or was consumed by the engine), so a field
    /// that does not match resets the composition one key late instead of keeping a wrong one.
    func pushLateFocusCheck(
        replaced: String, _ key: KeyInputContext, focus: FocusSnapshot, inputSource: InputSourceSnapshot
    ) -> Bool {
        keyState.lateFocusCheckPending = false
        let job = EditJob(
            sequence: context.queue.nextSequence(), generation: focus.generation, plan: focus.decision.plan,
            field: focus.fieldHandle, kind: .compose, deleteCount: 0, deleteUTF16Count: 0,
            replacedText: replaced.isEmpty ? nil : replaced, insertion: "",
            keyCodes: JobKeyCodes(trigger: key.event.keyCode, paste: seen.pasteKeyCode), trigger: nil,
            verifyBeforeApply: false, wordStartedNearFocusChange: false, createdAt: key.now, isProbe: key.probe,
            verifyLateFocus: true, caretEpoch: context.queue.caretEpoch)
        guard context.queue.push(.edit(job)) else { return false }
        lastPushWasBoundary = false
        return true
    }
}
