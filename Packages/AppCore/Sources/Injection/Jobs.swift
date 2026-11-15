// SPDX-License-Identifier: GPL-3.0-or-later
//
// Job model (PLT-R311, PLT-R401). Jobs are built on the tap thread and executed strictly FIFO on `inject`.

public import AppModel
public import RealtimeSupport

/// Injection parameters, converted once per focus change from the resolved rule decision (InputHost), so the
/// tap does no conversion and Injection never depends on the rule schema (PLT-R102).
public struct InjectionParameters: Sendable, Hashable {
    public var unicodeChunk: Int  // graphemes per event when 1; UTF-16 units cap when > 1 (PLT-R404)
    public var interEventDelayUs: Int
    public var postDeleteSettleUs: Int
    public var firstEditDelayUs: Int
    public var inlineCompletion: InlineCompletionMode
    public var allowMultiCharEvents: Bool
    public var allowSplit: Bool
    public var longTextThreshold: Int
    public var restoreDelayMs: Int
    public var verifyAfterEdit: Bool
    /// The user opted into `paste` for this app (PLT-R460, PLT-R480).
    public var pasteOptedIn: Bool

    public static let defaults = InjectionParameters(
        unicodeChunk: 1, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0,
        inlineCompletion: .none, allowMultiCharEvents: false, allowSplit: false, longTextThreshold: 64,
        restoreDelayMs: 400, verifyAfterEdit: false, pasteOptedIn: false)

    public init(
        unicodeChunk: Int, interEventDelayUs: Int, postDeleteSettleUs: Int, firstEditDelayUs: Int,
        inlineCompletion: InlineCompletionMode, allowMultiCharEvents: Bool, allowSplit: Bool,
        longTextThreshold: Int, restoreDelayMs: Int, verifyAfterEdit: Bool, pasteOptedIn: Bool
    ) {
        self.unicodeChunk = unicodeChunk
        self.interEventDelayUs = interEventDelayUs
        self.postDeleteSettleUs = postDeleteSettleUs
        self.firstEditDelayUs = firstEditDelayUs
        self.inlineCompletion = inlineCompletion
        self.allowMultiCharEvents = allowMultiCharEvents
        self.allowSplit = allowSplit
        self.longTextThreshold = longTextThreshold
        self.restoreDelayMs = restoreDelayMs
        self.verifyAfterEdit = verifyAfterEdit
        self.pasteOptedIn = pasteOptedIn
    }
}

public struct InjectionPlan: Sendable, Hashable {
    public var strategy: InjectionStrategy
    public var parameters: InjectionParameters
    public var fallback: [InjectionStrategy]

    public init(strategy: InjectionStrategy, parameters: InjectionParameters, fallback: [InjectionStrategy]) {
        self.strategy = strategy
        self.parameters = parameters
        self.fallback = fallback
    }

    public static let `default` = InjectionPlan(
        strategy: .backspaceReplace, parameters: .defaults, fallback: [.passThrough])
}

/// Accessibility element of the focused field, captured in the focus snapshot by the ax thread and carried by
/// jobs so the worker never reads snapshots. `element` is nil in tests.
public struct FieldHandle: Sendable, Hashable {
    public var pid: Int32
    /// Identity within one focus generation (fakes compare by token).
    public var token: UInt64
    public var element: AXElementReference?

    public init(pid: Int32, token: UInt64, element: AXElementReference?) {
        self.pid = pid
        self.token = token
        self.element = element
    }
}

/// Monotonic job sequence (also the low bits of the marker of the job's last synthetic event, PLT-R323).
public struct JobSequence: RawRepresentable, Sendable, Hashable, Comparable, BitwiseCopyable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: JobSequence, rhs: JobSequence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Copy of a held physical keyboard event (PLT-R324): keycode, flags, autorepeat, keyboard type and Unicode
/// string preserved; the replay adds the app's marker. Bitwise-copyable, so holding never allocates.
public struct KeyEventRecord: Sendable, Hashable, BitwiseCopyable {
    public enum Kind: UInt8, Sendable, Hashable, BitwiseCopyable { case keyDown, keyUp, flagsChanged }

    public var kind: Kind
    public var keyCode: KeyCode
    public var flags: UInt64  // CGEventFlags raw value
    public var autorepeat: Bool
    public var keyboardType: UInt32
    public var unicode: InlineUTF16
    /// Time the tap received the original (T5 held-wait metric, PLT-R314 liveness).
    public var receivedAt: MonotonicInstant
    /// Latency-probe event (PLT-R810). Replayed with the ordinary echo marker (a probe-kind marker would make the
    /// tap treat the replay as a new physical probe and hold it again); the worker routes metrics by this flag.
    public var isProbe: Bool

    public init(
        kind: Kind, keyCode: KeyCode, flags: UInt64, autorepeat: Bool, keyboardType: UInt32, unicode: InlineUTF16,
        receivedAt: MonotonicInstant, isProbe: Bool
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.autorepeat = autorepeat
        self.keyboardType = keyboardType
        self.unicode = unicode
        self.receivedAt = receivedAt
        self.isProbe = isProbe
    }
}

public enum EditKind: UInt8, Sendable, Hashable {
    case compose, backspaceRecompose, restore, macro, reentry
    /// PLT-R357: a commit that also revises the previous token (ENG-R828): one edit over the previous token, its
    /// space and the current token, before the boundary key is replayed.
    case revision
}

/// The text a commit left on screen for its token, kept as the pieces the tap already holds, so the tap builds no
/// string (PLT-R304): the worker computes `text`. Content: never logged, kept only until the next commit or reset
/// (PLT-R911).
public struct CommittedToken: Sendable, Hashable {
    /// The token's display before the commit.
    public var display: String
    /// Graphemes the commit edit deleted (0 without an edit); a revising commit deletes into the previous token.
    public var deleteCount: Int
    /// What the commit edit inserted (empty without an edit).
    public var insert: String

    public init(display: String, deleteCount: Int = 0, insert: String = "") {
        self.display = display
        self.deleteCount = deleteCount
        self.insert = insert
    }

    /// The token's text after the commit: the end of `display` the edit kept plus the insertion, from its last
    /// space on (a revising commit's insertion also holds the previous token and the space; words have no spaces).
    public var text: String {
        let kept = display.dropLast(min(deleteCount, display.count))
        let joined = String(kept) + insert
        guard let space = joined.lastIndex(of: " ") else { return joined }
        return String(joined[joined.index(after: space)...])
    }
}

/// PLT-R357: what the worker needs to verify a revision edit and, on a mismatch, to apply only the current token.
public struct RevisionEdit: Sendable, Hashable {
    /// The previous token as its own commit left it; nil when the pipeline does not know it.
    public var previous: CommittedToken?
    /// The current token's display before this commit: the end of the text the edit replaces.
    public var currentDisplay: String

    public init(previous: CommittedToken?, currentDisplay: String) {
        self.previous = previous
        self.currentDisplay = currentDisplay
    }

    /// The text before the caret the revision expects: the previous token, one space, the current display
    /// (ENG-R828: exactly one space between them). Nil when the previous token is unknown.
    public var expectedText: String? { previous.map { $0.text + " " + currentDisplay } }

    /// The current token's part of a revision that deletes `deleteCount` graphemes and inserts `insert`: delete
    /// its display, insert its new text.
    public func currentPart(deleteCount: Int, insert: String) -> (delete: String, insert: String) {
        (currentDisplay, CommittedToken(display: currentDisplay, deleteCount: deleteCount, insert: insert).text)
    }
}

/// Key codes resolved on the tap from the current layout table (PLT-R405, PLT-R461 step 3).
public struct JobKeyCodes: Sendable, Hashable {
    /// Keycode of the physical key that triggered the edit.
    public var trigger: KeyCode
    /// For restores, macros and an edit an action key triggered (`isActionKey`: Backspace, PLT-R352; Return, Tab or
    /// Space at a commit; Escape as the restore hotkey; PLT-R405): keycode of the first character of the insertion,
    /// or else of the replaced text, that the current layout types on a key without an action, so the insertion
    /// never rides on an action key's keycode.
    public var firstCharacter: KeyCode?
    /// Keycode producing "v" in the current layout (Command+V for `paste`).
    public var paste: KeyCode?

    public init(trigger: KeyCode, firstCharacter: KeyCode? = nil, paste: KeyCode? = nil) {
        self.trigger = trigger
        self.firstCharacter = firstCharacter
        self.paste = paste
    }

    /// PLT-R405: a key that can trigger an edit and whose keycode carries an action of its own in a text editor:
    /// Backspace, Return and keypad Enter, Tab, Space and Escape. (The other deletion key never triggers an edit,
    /// PLT-R340, and is never posted, PLT-R407.) Chromium (and so Electron) and WebKit derive the DOM `code` of a key
    /// event, and for a non-ASCII character also the legacy `keyCode`, from the virtual keycode, so a Unicode event
    /// posted on one of these keys reaches an editor that acts on `code` or `keyCode` as that key: it deletes, sends,
    /// moves the focus or cancels instead of typing. No Unicode event rides on these keycodes. Tap-safe.
    @inline(__always)
    public static func isActionKey(_ keyCode: KeyCode) -> Bool {
        switch keyCode {
        case .delete, .returnKey, .keypadEnter, .tab, .space, .escape: true
        default: false
        }
    }
}

/// PLT-R401. Content (insertion, replacedText) lives only in memory and is never logged.
public struct EditJob: Sendable {
    public var sequence: JobSequence
    public var generation: FocusGeneration
    public var plan: InjectionPlan
    public var field: FieldHandle?
    public var kind: EditKind
    /// Grapheme clusters the engine emitted (PLT-R403, ENG-R630).
    public var deleteCount: Int
    public var deleteUTF16Count: Int
    /// The text expected before the caret that the edit replaces, when the pipeline knows it. Used for prefix
    /// trimming (PLT-R402) and bounded re-entry verification (PLT-R342).
    public var replacedText: String?
    /// NFC (PLT-R403).
    public var insertion: String
    public var keyCodes: JobKeyCodes
    /// The physical key that triggered the edit. If the job is abandoned (liveness flush or generation
    /// discard) the worker replays it, so the conservation invariant still holds (PLT-R312). Nil when the
    /// original key is already queued as a replay (`thenPassThrough`).
    public var trigger: KeyEventRecord?
    /// Re-entry into a committed word: verify before applying when the rule allows (PLT-R342). The pipeline sets it
    /// for every edit of a word re-opened by Backspace when `verifyReentry != .never` (`.reentry`, and also
    /// `.macro` and `.restore`, which keep their kind); the worker honours it for every kind.
    public var verifyBeforeApply: Bool
    /// The word began within 300 ms of a focus change or click (`firstEditDelayUs`, PLT-R408).
    public var wordStartedNearFocusChange: Bool
    public var createdAt: MonotonicInstant
    public var isProbe: Bool
    /// PLT-R340 amendment (2026-11-14): the first job after a focus change the tap discovered late, when it kept
    /// the composition. The worker applies it only if `field` is readable and its text before the caret (before the
    /// selection, when an inline completion is selected) ends with `replacedText`; otherwise the trigger passes
    /// through and the composition is reset. Strict, unlike `verifyBeforeApply`: an unreadable field fails.
    public var verifyLateFocus: Bool
    /// Kind `.revision` only (PLT-R357): the previous token and the current display, for the PLT-R342 check.
    public var revision: RevisionEdit?

    public init(
        sequence: JobSequence, generation: FocusGeneration, plan: InjectionPlan, field: FieldHandle?,
        kind: EditKind, deleteCount: Int, deleteUTF16Count: Int, replacedText: String?, insertion: String,
        keyCodes: JobKeyCodes, trigger: KeyEventRecord?, verifyBeforeApply: Bool,
        wordStartedNearFocusChange: Bool, createdAt: MonotonicInstant, isProbe: Bool, verifyLateFocus: Bool = false,
        revision: RevisionEdit? = nil
    ) {
        self.sequence = sequence
        self.generation = generation
        self.plan = plan
        self.field = field
        self.kind = kind
        self.deleteCount = deleteCount
        self.deleteUTF16Count = deleteUTF16Count
        self.replacedText = replacedText
        self.insertion = insertion
        self.keyCodes = keyCodes
        self.trigger = trigger
        self.verifyBeforeApply = verifyBeforeApply
        self.wordStartedNearFocusChange = wordStartedNearFocusChange
        self.createdAt = createdAt
        self.isProbe = isProbe
        self.verifyLateFocus = verifyLateFocus
        self.revision = revision
    }
}

public enum BoundaryReason: UInt8, Sendable, Hashable {
    case mouseDown, focusChanged, navigation, commandChord, returnOrTab, escape, modeToggled, inputSourceChanged,
        secureInputChanged, tapReenabled, settingsChanged, ruleChanged, sessionChanged
    /// PLT-R397A: a keyUp whose keyDown the tap never saw: the app received input the engine did not see.
    case unseenInput
}

/// Marks a hard boundary in FIFO order (PLT-R340). The worker resets first-edit timing (PLT-R408); paste
/// coalescing (PLT-R461 step 6) is bounded by `restoreDelayMs` and the `changeCount` guard, not by boundaries.
public struct BoundaryJob: Sendable, Hashable {
    public var sequence: JobSequence
    public var reason: BoundaryReason
    public var generation: FocusGeneration
    public init(sequence: JobSequence, reason: BoundaryReason, generation: FocusGeneration) {
        self.sequence = sequence
        self.reason = reason
        self.generation = generation
    }
}

public enum InjectionJob: Sendable {
    case edit(EditJob)
    case replay(JobSequence, KeyEventRecord)
    /// keyUp of a keyDown consumed for `job`: dropped if the job executed, replayed if it was abandoned
    /// (PLT-R313 with conservation).
    case pairedKeyUp(JobSequence, KeyEventRecord, forJob: JobSequence)
    case boundary(BoundaryJob)
}
