// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus revalidation requests from the tap (PLT-R382, PLT-R389) and the caret continuity of PLT-R423 (amendment of
// 2026-11-16). Tap-safe: integer tests, one ring push, one atomic increment and a wake-up; no AX, I/O, lock or
// allocation (PLT-R304, PLT-R305). The tap never waits for a read: what it asks for is read on the ax thread, and a
// key that met a stale snapshot is protected by the worker's generation check (PLT-R316) and, after a late focus
// change (KeyPipeline+LateFocus.swift), by the bounded read of the first job (`EditJob.verifyLateFocus`).

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

    /// PLT-R340 amendment of 19/11/2026 (review): a trigger whose new focus can come a moment after the key, so the
    /// late focus rule may waive the first-key window for a word typed right after it: a Command or Control shortcut
    /// (Command+S attaches a sheet, Command+K opens a panel). Return, Tab and Escape move the focus at once (the read
    /// they ask for already finds the new element) and most often move nothing (a newline, a closed completion),
    /// so they never waive it. A click counts too (`notePointerDownForRevalidation`). Pure, tap-safe.
    @inline(__always)
    static func mayMoveFocusLater(_ event: RawKeyEvent) -> Bool {
        event.flags & (EventFlags.command | EventFlags.control) != 0
    }
}

/// PLT-R423 caret continuity (amendment of 16/11/2026, second retest of beta 2): the worker keeps an earlier completion
/// read's "caret at the end of the text" for a later read that does not answer only while the tap has seen nothing
/// that can move the caret since. The tap breaks the continuity (`JobQueue.breakCaretContinuity`) at every hard
/// boundary (`hardBoundary`), at every keyDown this type does not count as typing, in every host state, and at the
/// first keyDown after a typing pause (PLT-R382).
enum CaretContinuity {
    /// A keyDown that types one character (a letter, digit, punctuation or space, with Shift or Option at most) or a
    /// Backspace without Option: at the end of the text it inserts or deletes before the caret, and the caret stays at
    /// the end. Every other keyDown may move the caret or select text: an arrow, Home, End, Page Up or Down, Forward
    /// Delete, Option+Backspace, any Command or Control chord (Command+A selects all, Command+V pastes, Command+Z
    /// undoes), Return, Tab, Escape, a function key. Pure, tap-safe.
    @inline(__always)
    static func keepsCaret(_ event: RawKeyEvent) -> Bool {
        if event.flags & (EventFlags.command | EventFlags.control) != 0 { return false }
        switch VirtualKeyGroup.of(event.keyCode) {
        case .other: return true
        case .backspace: return event.flags & EventFlags.option == 0
        case .forwardDelete, .escape, .returnKey, .tab, .navigation, .function: return false
        }
    }
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
        guard event.kind == .keyDown else { return }
        // An autorepeat is never idle (repeats follow each other within the typing rhythm) and never a new press.
        let idle =
            !event.autorepeat
            && (keyState.lastKeyboardEventAt.map { now.nanoseconds(since: $0) >= FocusRevalidation.idleNanoseconds }
                ?? true)
        // PLT-R423 amendment: before any state check, so keys that bypass the engine (English mode, a pause, a
        // passThrough rule, fail-open) count too.
        if idle || !CaretContinuity.keepsCaret(event) { context.queue.breakCaretContinuity() }
        guard !event.autorepeat else { return }
        if FocusRevalidation.mayMoveFocus(event) {
            keyState.revalidateNextKey = true
            // PLT-R340 amendment of 19/11/2026: a word typed right after a shortcut may be measured from its last key.
            if FocusRevalidation.mayMoveFocusLater(event) { keyState.lastFocusTriggerAt = now }
            requestFocusRevalidation(.revalidateFocusAfterTrigger)
            return
        }
        guard idle || keyState.revalidateNextKey || focus.decision.overlay else { return }
        keyState.revalidateNextKey = false
        // The PLT-R382 read is a full one (the same element's attributes may have changed during the pause); the
        // PLT-R389 reads only look further when the focused app or element moved.
        requestFocusRevalidation(idle ? .revalidateFocus : .revalidateFocusIfMoved)
    }

    /// PLT-R389: a click may move the focus into or out of a non-activating panel.
    func notePointerDownForRevalidation(now: MonotonicInstant) {
        keyState.revalidateNextKey = true
        keyState.lastFocusTriggerAt = now
        requestFocusRevalidation(.revalidateFocusAfterTrigger)
    }

    /// One lock-free push and a wake-up; a full ring drops the request (the next key or notification reads again).
    @inline(__always)
    func requestFocusRevalidation(_ notice: AXNotice) {
        if context.outbox.toAX.push(notice) { context.outbox.axSignal.signal() }
    }
}
