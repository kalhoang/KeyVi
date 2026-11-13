// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Tap-thread state of `KeyPipeline` (contracts.md 10.1). Only trivially copyable values: the pipeline keeps no
// strings or arrays across callbacks, so nothing it holds can be the last reference to snapshot memory and no
// deallocation happens on the tap (ADR 0303), and no typed content outlives the composition (PLT-R911).

internal import AppModel
internal import Injection
internal import RealtimeSupport

/// Keycode -> how its consumed keyDown was handled, so the matching keyUp is consumed too (PLT-R313, ADR 0308).
/// One fixed allocation at creation; every operation is an index into it.
final class ConsumedKeyTable {
    enum Entry: Equatable {
        case none
        /// Consumed as a hotkey combo (contracts.md 10.2).
        case hotkey
        /// Consumed by an empty edit: no job, nothing to deliver.
        case withoutJob
        case job(JobSequence)
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

    // 0 = none, 1 = hotkey, 2 = withoutJob, (sequence << 2) | 3 = job.
    @inline(__always)
    private static func encode(_ entry: Entry) -> UInt64 {
        switch entry {
        case .none: 0
        case .hotkey: 1
        case .withoutJob: 2
        case .job(let sequence): (sequence.rawValue << 2) | 3
        }
    }

    @inline(__always)
    private static func decode(_ value: UInt64) -> Entry {
        switch value & 3 {
        case 1: .hotkey
        case 2: .withoutJob
        case 3: .job(JobSequence(rawValue: value >> 2))
        default: .none
        }
    }
}

/// The parts of a focus snapshot whose change is a hard boundary (PLT-R340): the focus owner and element
/// (focus change), and the resolved decision (rule or strategy change). Republication with the same owner and
/// decision (for example after the ax thread applied a toggle) is not a boundary.
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

    init(_ focus: FocusSnapshot) {
        generation = focus.generation
        pid = focus.app?.pid ?? ToggleOverride.noProcess
        fieldToken = focus.fieldHandle?.token
        decision = Decision(
            strategy: focus.decision.plan.strategy, parameters: focus.decision.plan.parameters,
            variant: focus.decision.variant, requireTextFocus: focus.decision.requireTextFocus,
            pause: focus.pause?.code)
    }

    /// Same app and the same element token. A token is the ax thread's element identity; without one (AX
    /// unavailable or timed out) the element is unknown, so a new generation counts as a focus change
    /// (PLT-R210, ENG-R1010: the host cannot vouch for the text before the caret).
    func sameOwner(as other: FocusIdentity) -> Bool {
        guard let fieldToken, let otherToken = other.fieldToken else { return false }
        return pid == other.pid && fieldToken == otherToken
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
    /// PLT-R398B: a secure-input release was seen (key evidence, or a new generation with the OS flag off) and the
    /// next key-down is the first one after it (`HostCounters`).
    var awaitingKeyAfterSecureRelease = false
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
    var lastPointerDownAt: MonotonicInstant?
    /// PLT-R382 idle revalidation.
    var lastKeyboardEventAt: MonotonicInstant?
    /// Keyboard type already reported to the main thread (`MainNotice.keyboardTypeSeen`).
    var reportedKeyboardType: UInt32?
    /// PLT-R398B: the key being processed was fed to the engine (`compose`). Cleared before the first key-down
    /// after a secure-input release and read when that key's verdict is ready (`HostCounters`).
    var engineFedByThisKey = false
}
