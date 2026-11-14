// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus revalidation requests from the tap (PLT-R382, PLT-R389) and the late focus change (PLT-R340 amendment of
// 2026-11-14). Tap-safe: integer tests, one ring push and a wake-up; no AX, I/O, lock or allocation (PLT-R304,
// PLT-R305). The tap never waits for a read: what it asks for is read on the ax thread, and a key that met a stale
// snapshot is protected by the worker's generation check (PLT-R316) and, after a late focus change, by the
// bounded read of the first job (`EditJob.verifyLateFocus`).

internal import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport

/// When the tap asks the ax thread to read the system-wide focus again.
enum FocusRevalidation {
    /// PLT-R382: a keyDown after this much keyboard silence revalidates.
    static let idleNanoseconds: UInt64 = 500_000_000

    /// PLT-R389: a keyDown that can move the focus without an app activation notification: any Command or Control
    /// shortcut (Command+Space opens Spotlight, Command+S opens a save sheet), Escape (closes Spotlight, a sheet or a
    /// popover), Return and Tab. Autorepeat does not count: the first press already asked. Pure, tap-safe.
    @inline(__always)
    static func mayMoveFocus(_ event: RawKeyEvent) -> Bool {
        guard event.kind == .keyDown, !event.autorepeat else { return false }
        if event.flags & (EventFlags.command | EventFlags.control) != 0 { return true }
        switch VirtualKeyGroup.of(event.keyCode) {
        case .escape, .returnKey, .tab: return true
        case .backspace, .forwardDelete, .navigation, .function, .other: return false
        }
    }
}

/// PLT-R340 amendment (product owner, 2026-11-14, T5.5): a focus change the tap discovers after keys of the active
/// token were composed with the previous snapshot keeps the composition when the new element belongs to the same
/// process and the change was observed at most `windowNanoseconds` after the token's last key. The first job after
/// the discovery verifies the new element's text before the caret (`EditJob.verifyLateFocus`).
enum LateFocusChange {
    /// 500 ms: the ax thread observes a focus change that the typing caused (a sheet or an editor taking the key it
    /// was opened by) or that the app reported late within its settle window (last re-read 400 ms after the
    /// notification, `FocusSettle.delays`, PLT-R380) plus scheduling slack; it equals the PLT-R382 typing-pause
    /// threshold, beyond which a key no longer belongs to continuous typing. A change observed later is not part of
    /// the word and stays a hard boundary.
    static let windowNanoseconds: UInt64 = 500_000_000
}

extension KeyPipeline {
    /// PLT-R382 and PLT-R389, called for every keyboard event before reconciliation. A trigger asks for the read
    /// over the settle window, because the panel or sheet it opens takes the focus only after the tap returned the
    /// key; the next keyDown asks for one more read. While the focus owner's rule is an overlay rule, every keyDown
    /// asks, because closing the panel (Escape, a click outside, Return) posts no activation. Those two reads ask
    /// for the element's attributes only when the focused app or element moved (`.revalidateFocusIfMoved`). The first keyDown after
    /// start counts as idle: the pause before it has no known length, and a focus notification missed right after
    /// launch would otherwise leave the first word on a stale snapshot.
    func noteKeyboardActivity(_ event: RawKeyEvent, now: MonotonicInstant, focus: FocusSnapshot) {
        defer { keyState.lastKeyboardEventAt = now }
        // An autorepeat is never idle (repeats follow each other within the typing rhythm) and never a new press.
        guard event.kind == .keyDown, !event.autorepeat else { return }
        if FocusRevalidation.mayMoveFocus(event) {
            keyState.revalidateNextKey = true
            requestFocusRevalidation(.revalidateFocusAfterTrigger)
            return
        }
        let idle =
            keyState.lastKeyboardEventAt.map { now.nanoseconds(since: $0) >= FocusRevalidation.idleNanoseconds } ?? true
        guard idle || keyState.revalidateNextKey || focus.decision.overlay else { return }
        keyState.revalidateNextKey = false
        // The PLT-R382 read is a full one (the same element's attributes may have changed during the pause); the
        // PLT-R389 reads only look further when the focused app or element moved.
        requestFocusRevalidation(idle ? .revalidateFocus : .revalidateFocusIfMoved)
    }

    /// PLT-R389: a click may move the focus into or out of a non-activating panel.
    func notePointerDownForRevalidation() {
        keyState.revalidateNextKey = true
        requestFocusRevalidation(.revalidateFocusAfterTrigger)
    }

    /// One lock-free push and a wake-up; a full ring drops the request (the next key or notification reads again).
    @inline(__always)
    func requestFocusRevalidation(_ notice: AXNotice) {
        if context.outbox.toAX.push(notice) { context.outbox.axSignal.signal() }
    }

    /// PLT-R340 amendment: keep the composition across a focus change discovered after keys of the active token
    /// were composed with the previous snapshot. Same process (or a previous snapshot that names no process because
    /// its system-wide focus read timed out, amendment of 2026-11-15: Pa's Safari trace), an element the worker can
    /// read (a field handle and AX available), no focus pause, the same engine variant, and the change observed at
    /// most `LateFocusChange.windowNanoseconds` after the token's last key. Everything else stays a hard boundary.
    /// The active-display read runs only on this rare path (a new element while a word is being typed).
    func keepsCompositionAcrossLateFocusChange(_ focus: FocusSnapshot, identity: FocusIdentity) -> Bool {
        let sameProcess = identity.pid == seen.focus.pid || seen.focus.appUnknownAfterTimeout
        guard engineDirty, identity.pid != ToggleOverride.noProcess, sameProcess,
            focus.fieldHandle != nil, focus.field.axAvailability == .available, focus.pause == nil,
            identity.decision.variant == seen.focus.decision.variant, let lastKey = keyState.lastComposedKeyAt,
            focus.changedAt.nanoseconds(since: lastKey) <= LateFocusChange.windowNanoseconds
        else { return false }
        return !engine.activeDisplay.isEmpty
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
            verifyLateFocus: true)
        guard context.queue.push(.edit(job)) else { return false }
        lastPushWasBoundary = false
        return true
    }
}
