// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel
public import RealtimeSupport
public import VietnameseEngine

/// The fields of a `CGEvent` the pipeline needs, read once in the callback adapter (PLT-R304 "reading event
/// fields"). Bitwise-copyable: no allocation per event.
public struct RawKeyEvent: Sendable, Hashable, BitwiseCopyable {
    public enum Kind: UInt8, Sendable, Hashable, BitwiseCopyable {
        case keyDown, keyUp, flagsChanged
        case leftMouseDown, rightMouseDown, otherMouseDown
        case scrollWheel  // only if the toggle recogniser needs it (PLT-R301)
        case tapDisabledByTimeout, tapDisabledByUserInput
    }

    public var kind: Kind
    public var keyCode: KeyCode
    public var flags: UInt64  // CGEventFlags raw value
    public var autorepeat: Bool  // kCGKeyboardEventAutorepeat
    public var keyboardType: UInt32  // kCGKeyboardEventKeyboardType
    public var unicode: InlineUTF16  // CGEventKeyboardGetUnicodeString (debug cross-check, PLT-R363)
    public var userData: Int64  // kCGEventSourceUserData (marker, PLT-R321)
    public var receivedAt: MonotonicInstant

    public init(
        kind: Kind, keyCode: KeyCode, flags: UInt64, autorepeat: Bool, keyboardType: UInt32, unicode: InlineUTF16,
        userData: Int64, receivedAt: MonotonicInstant
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.autorepeat = autorepeat
        self.keyboardType = keyboardType
        self.unicode = unicode
        self.userData = userData
        self.receivedAt = receivedAt
    }
}

/// Return value of the callback: the event unchanged, or NULL (PLT-R310 step 10).
public enum TapVerdict: Sendable, Hashable {
    case pass
    case swallow
}

/// Step 7 classification (PLT-R310, PLT-R350-R356).
public enum KeyClass: Sendable, Hashable {
    case character(Character, fromKeypad: Bool)
    case backspace
    case forwardDelete
    case navigation
    case escape
    case returnKey
    case tab
    case commandOrControlChord
    /// Option chord producing a character: pass through, hard boundary (PLT-R350).
    case optionChord
    case deadKey
    case functionKey
    case modifierOnly
    case unmapped
}

/// Content-free outcome of one physical event, for the conservation ledger (PLT-R312) and the capture.
public enum EventOutcome: UInt8, Sendable, Hashable {
    case passed
    case held  // swallowed, ReplayJob pushed
    case consumedForEdit  // EditJob pushed (trigger replayed if abandoned)
    case consumedPairedKeyUp  // keyUp of a consumed keyDown
    case consumedAsHotkey
}

/// Tap -> main notices, carried by an SPSC ring and a `WakeSignal`.
public enum MainNotice: Sendable {
    case modeToggled(sequence: UInt64, bundle: BundleKey?, mode: TypingMode)
    case secureInputResumedByKey(generation: UInt64)
    case tapDisabled(byTimeout: Bool)
    /// ENG-R861, memory only. ENG-R862: `bundle` is the app of the focus snapshot the token was committed in, read
    /// on the tap with the snapshot it already holds, so the word belongs to that app whenever main drains the
    /// outbox (the focus may have moved by then).
    case learning(LearningSignal, bundle: BundleKey?)
    /// First echo miss of a run: the utility queue checks `CGPreflightPostEventAccess()` (ADR 0311).
    case echoMissed
    /// Three consecutive misses: the tap already failed open in this callback (PLT-R730).
    case postingBroken
    case keyboardTypeSeen(UInt32)
}

/// Tap -> ax notices.
public enum AXNotice: Sendable {
    case modeToggled(sequence: UInt64, bundle: BundleKey?, mode: TypingMode)
    /// Read the system-wide focus now: the first key after a typing pause (PLT-R382), the first key after an event
    /// that can move the focus, and every key while an overlay rule applies (PLT-R389).
    case revalidateFocus
    /// PLT-R389: a Command or Control shortcut, Escape, Return, Tab or a click may move the focus without an app
    /// activation (a non-activating panel such as Spotlight opens or closes, a sheet takes the focus). The ax
    /// thread reads the system-wide focus over the trigger settle window (`FocusSettle.triggerDelays`).
    case revalidateFocusAfterTrigger
}

/// The two outboxes and their wake-ups.
public final class TapOutbox: Sendable {
    public let toMain: SPSCRing<MainNotice>
    public let toAX: SPSCRing<AXNotice>
    public let mainSignal: WakeSignal
    public let axSignal: WakeSignal

    public init(toMain: SPSCRing<MainNotice>, toAX: SPSCRing<AXNotice>, mainSignal: WakeSignal, axSignal: WakeSignal) {
        self.toMain = toMain
        self.toAX = toAX
        self.mainSignal = mainSignal
        self.axSignal = axSignal
    }
}
