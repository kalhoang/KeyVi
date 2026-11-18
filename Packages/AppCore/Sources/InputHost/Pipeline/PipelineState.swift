// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tap-thread state of `KeyPipeline` (contracts.md 10.1). Only trivially copyable values: the pipeline keeps no
// strings or arrays across callbacks, so nothing it holds can be the last reference to snapshot memory and no
// deallocation happens on the tap (ADR 0303), and no typed content outlives the composition (PLT-R911).

internal import AppModel
internal import Injection
internal import RealtimeSupport

/// Keycode -> how its last keyDown was handled, so the matching keyUp follows it: consumed with a consumed keyDown
/// (PLT-R313, ADR 0308), passed with a passed one (PLT-R311 amendment, ADR 0322), held behind a held one.
/// One fixed allocation at creation; every operation is an index into it.
final class ConsumedKeyTable {
    enum Entry: Equatable {
        case none
        /// Consumed as a hotkey combo (contracts.md 10.2).
        case hotkey
        /// Consumed by an empty edit: no job, nothing to deliver.
        case withoutJob
        case job(JobSequence)
        /// The keyDown (or its last autorepeat) reached the app unchanged: its keyUp passes, even while a job is in
        /// flight (ADR 0322).
        case passedDown
        /// The keyDown (or its last autorepeat) is queued as a replay: its keyUp is held behind it (PLT-R311).
        case heldDown
    }

    /// Virtual key codes are below 128 on every Mac keyboard; 256 leaves room. Larger codes are not tracked.
    static let capacity = 256
    private let slots: UnsafeMutablePointer<UInt64>

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { slots.deallocate() }

    @inline(__always)
    func entry(_ keyCode: KeyCode) -> Entry {
        guard let slot = Self.slot(keyCode) else { return .none }
        return Self.decode(slots[slot])
    }

    @inline(__always)
    func set(_ keyCode: KeyCode, _ entry: Entry) {
        guard let slot = Self.slot(keyCode) else { return }
        slots[slot] = Self.encode(entry)
    }

    /// Reads and clears the entry (on the keyUp).
    @inline(__always)
    func take(_ keyCode: KeyCode) -> Entry {
        guard let slot = Self.slot(keyCode) else { return .none }
        let value = slots[slot]
        slots[slot] = 0
        return Self.decode(value)
    }

    @inline(__always)
    private static func slot(_ keyCode: KeyCode) -> Int? {
        let index = Int(keyCode.rawValue)
        return index < capacity ? index : nil
    }

    // 0 = none, 1 = hotkey, 2 = withoutJob, 4 = passedDown, 8 = heldDown, (sequence << 2) | 3 = job.
    @inline(__always)
    private static func encode(_ entry: Entry) -> UInt64 {
        switch entry {
        case .none: 0
        case .hotkey: 1
        case .withoutJob: 2
        case .passedDown: 4
        case .heldDown: 8
        case .job(let sequence): (sequence.rawValue << 2) | 3
        }
    }

    @inline(__always)
    private static func decode(_ value: UInt64) -> Entry {
        if value & 3 == 3 { return .job(JobSequence(rawValue: value >> 2)) }
        switch value {
        case 1: return .hotkey
        case 2: return .withoutJob
        case 4: return .passedDown
        case 8: return .heldDown
        default: return .none
        }
    }
}

/// The parts of a focus snapshot whose change is a hard boundary (PLT-R340): the focus owner and element
/// (focus change), and the resolved decision (rule or strategy change). Republication with the same owner and
/// decision (for example after the ax thread applied a toggle) is not a boundary. Also what the late focus rule
/// compares with: when the element was observed and whether the worker can read it.
struct FocusIdentity: Equatable {
    struct Decision: Equatable {
        var strategy: InjectionStrategy
        var parameters: InjectionParameters
        var variant: EngineVariant
        var requireTextFocus: RequireTextFocus
        var pause: PauseCode?
    }

    var generation: FocusGeneration
    var pid: Int32
    var fieldToken: UInt64?
    var decision: Decision
    /// No app, because the system-wide focus read timed out (not because AX named none): the app is unknown, not
    /// changed (PLT-R340 late focus change, amendment of 2026-11-15).
    var appUnknownAfterTimeout: Bool
    /// No app, because the system-wide focus read timed out or failed: the focus is unknown there, not elsewhere, so
    /// the last element survives it, as on the ax thread (`FocusCore.keepsLastElement`, PLT-R340, PLT-R384).
    var appUnknown: Bool
    /// No element although AX answered (no focused element, the PLT-R381 frontmost fallback): keys typed while this
    /// held did not go into the last element (PLT-R340 amendment of 19/11/2026, review).
    var answeredNoElement: Bool
    /// When the ax thread observed the element (`FocusSnapshot.changedAt`).
    var changedAt: MonotonicInstant
    /// A field handle and AX available: the worker can read the element (the late focus check, PLT-R340).
    var readable: Bool

    init(_ focus: FocusSnapshot) {
        generation = focus.generation
        pid = focus.app?.pid ?? ToggleOverride.noProcess
        appUnknownAfterTimeout = focus.app == nil && focus.field.axAvailability == .timedOut
        appUnknown = focus.app == nil && focus.field.axAvailability != .available
        answeredNoElement = focus.fieldHandle == nil && focus.field.axAvailability == .available
        fieldToken = focus.fieldHandle?.token
        decision = Decision(
            strategy: focus.decision.plan.strategy, parameters: focus.decision.plan.parameters,
            variant: focus.decision.variant, requireTextFocus: focus.decision.requireTextFocus,
            pause: focus.pause?.code)
        changedAt = focus.changedAt
        readable = focus.isReadableForLateFocusCheck
    }
}

extension FocusSnapshot {
    /// A field handle and AX available: the worker can read the element (the late focus check, PLT-R340).
    var isReadableForLateFocusCheck: Bool { fieldHandle != nil && field.axAvailability == .available }
}

/// PLT-R340 amendment of 19/11/2026: a focus the late focus rule compares a new snapshot with. A token is the ax
/// thread's element identity (contracts.md 10.4); without one the element is unknown.
struct FocusReference: Equatable {
    var pid: Int32
    var token: UInt64?
    var changedAt: MonotonicInstant
    var appUnknownAfterTimeout: Bool
    /// The decision resolved for it: the element found again is compared with this one, not with a snapshot
    /// without its attributes in between (whose rules could not see the field).
    var decision: FocusIdentity.Decision

    init(_ identity: FocusIdentity) {
        pid = identity.pid
        token = identity.fieldToken
        changedAt = identity.changedAt
        appUnknownAfterTimeout = identity.appUnknownAfterTimeout
        decision = identity.decision
    }

    /// Same process and the same element token.
    func names(_ identity: FocusIdentity) -> Bool {
        guard let token, let other = identity.fieldToken else { return false }
        return pid == identity.pid && token == other
    }
}

/// Generations and values the pipeline last reconciled against (PLT-R210, PLT-R340, PLT-R1008).
struct ObservedState {
    var settingsGeneration: UInt64
    var focus: FocusIdentity
    var engineVariant: EngineVariant
    var inputSourceGeneration: UInt64
    var secureGeneration: UInt64
    var lifecycleGeneration: UInt64
    var resetCount: UInt64
    var stateCode: HostStateCode?
    /// PLT-R398B: the secure-input generation that key evidence ended.
    var secureResumedGeneration: UInt64?
    var postingBroken: Bool
    var echoMisses = 0
    /// Consecutive misses already present when posting recovered (EchoTracker keeps counting until an echo).
    var missBaseline = 0
    /// Keycode producing "v" in the current layout (Command+V for `paste`, PLT-R461 step 3).
    var pasteKeyCode: KeyCode?
    /// `EngineCatalog.revision` of the engine in use (nil: unknown, every settings generation rebuilds).
    var engineRevision: UInt64?
    /// `EngineCatalog.memoryRevision` of the engine in use (ENG-R865).
    var memoryRevision: UInt64 = 0
    /// A catalog with a new learned memory and the same settings arrived: the engine is swapped at the next hard
    /// boundary, when it is clean, so the word being typed is kept (ENG-R865, ENG-R1211).
    var memorySwapPending = false
    /// PLT-R398B: a secure-input release was seen (key evidence, or a new generation with the OS flag off) and the
    /// next key-down is the first one after it (`HostCounters`).
    var awaitingKeyAfterSecureRelease = false
    /// PLT-R340 amendment of 19/11/2026: the last snapshot that carried a field token, kept across snapshots without
    /// one that name its process or no process after a timed-out read (the ax thread keeps the token of an element
    /// it finds again after such snapshots, `FocusCore.lastElement`). A snapshot with this token is the same element.
    var lastElement: FocusReference?
    /// When AX first answered that no element of `lastElement`'s process had the focus (`answeredNoElement`) since
    /// that element was last named; nil while no such snapshot came. Keys composed after it make the element found
    /// again a checked keep (`LateFocusReason.backFromNoElement`).
    var noElementAnsweredAt: MonotonicInstant?
}

/// Per-key bookkeeping that is not a snapshot generation.
struct KeyState {
    /// PLT-R354: a dead key was passed; the next keyDown passes untouched too. Cleared only by that keyDown
    /// or a pointer down, never by a reconciliation: the OS still combines the next key with the dead key.
    var deadKeyPending = false
    /// PLT-R342, ENG-R1002: a Backspace re-opened the previous, committed word; edits of it are re-entries
    /// until the word is committed again or a hard boundary drops the history.
    var reopenedWord = false
    /// First key of the current word (PLT-R408 `wordStartedNearFocusChange`).
    var wordStartedAt: MonotonicInstant?
    /// PLT-R340 amendment of 19/11/2026: the element the active word began in, while snapshots of its process without
    /// a readable element kept the word; the next snapshot is judged against it. Cleared with the word.
    var wordReference: FocusReference?
    /// PLT-R389: the last Command or Control shortcut or click, whose new focus can come a moment later (the late
    /// focus rule's trigger, PLT-R340, `FocusRevalidation.mayMoveFocusLater`).
    var lastFocusTriggerAt: MonotonicInstant?
    var lastPointerDownAt: MonotonicInstant?
    /// PLT-R382 idle revalidation.
    var lastKeyboardEventAt: MonotonicInstant?
    /// PLT-R389: an event that can move the focus was seen; the next keyDown asks for one more read.
    var revalidateNextKey = false
    /// Last key fed to the engine (`compose`): the late focus change window starts there (PLT-R340 amendment).
    var lastComposedKeyAt: MonotonicInstant?
    /// PLT-R340 amendment: a late focus change kept the composition; the next job verifies the new element's text
    /// before the caret (`EditJob.verifyLateFocus`). Cleared by that job and by every engine reset.
    var lateFocusCheckPending = false
    /// The engine committed a token since its last reset or build, so its state holds more than the active word
    /// and cannot continue with another engine (ENG-R1211 amendment of 19/11/2026). Set by an output that carries a
    /// commit decision; cleared with the engine.
    var committedSinceEngineReset = false
    /// Keyboard type already reported to the main thread (`MainNotice.keyboardTypeSeen`).
    var reportedKeyboardType: UInt32?
    /// PLT-R398B: the key being processed was fed to the engine (`compose`). Cleared before the first key-down
    /// after a secure-input release and read when that key's verdict is ready (`HostCounters`).
    var engineFedByThisKey = false
    /// PLT-R397A: key codes the tap saw go down and not yet up.
    var keysDown = KeysDown()
    /// PLT-R357: the newest committed token as its commit left it, for the PLT-R342 check of a revision of it by the
    /// next commit. Pieces the engine output already holds (no string is built on the tap); cleared by every
    /// engine reset and restore, so it never outlives the engine's own history (PLT-R911).
    var lastCommit: CommittedToken?
}
