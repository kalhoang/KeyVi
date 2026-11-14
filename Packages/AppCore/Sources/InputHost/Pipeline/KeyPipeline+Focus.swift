// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus revalidation requests from the tap (PLT-R382, PLT-R389). Tap-safe: integer tests, one ring push and a
// wake-up; no AX, I/O, lock or allocation (PLT-R304, PLT-R305). The tap never waits for a read: what it asks for is
// read on the ax thread, and a key that met a stale snapshot is protected by the worker's generation check
// (PLT-R316).

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

extension KeyPipeline {
    /// PLT-R382 and PLT-R389, called for every keyboard event before reconciliation. A trigger asks for the read
    /// over the settle window, because the panel or sheet it opens takes the focus only after the tap returned the
    /// key; the next keyDown asks for one more read. While the focus owner's rule is an overlay rule, every keyDown
    /// asks, because closing the panel (Escape, a click outside, Return) posts no activation. The first keyDown after
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
        requestFocusRevalidation(.revalidateFocus)
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
}
