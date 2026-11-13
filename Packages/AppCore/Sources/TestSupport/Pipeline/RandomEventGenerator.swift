// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Seeded generator for the pipeline property suites (02-platform.md 13.1). Plausible input: keys are pressed
// and released (with rollover and autorepeat), modifier flags follow the held modifiers, Control+Shift taps
// happen, and host events (focus, secure input, permission, posting) interleave with worker and server steps.
// Time between server drains stays below 100 ms (stalls of the worker drain first) so a lagging WindowServer
// never holds an echo longer than the 200 ms echo timeout (a lag the design does not claim to survive).

internal import AppModel
internal import InputHost
internal import RealtimeSupport

/// SplitMix64: tiny, fast, good enough for test interleavings, and stable across Swift versions.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

struct GeneratorCore {
    /// Letters the scripted engine reacts to, a separator, editing and navigation keys, a keypad digit and a
    /// function key (ANSI virtual key codes).
    static let keyPool: [UInt16] = [
        0x00, 0x00, 0x01, 0x0D, 0x07, 0x02, 0x0E, 0x2D, 0x1F, 0x20,  // a a s w x d e n o u
        0x31, 0x31, 0x2B,  // space space comma
        0x33, 0x24, 0x30, 0x35, 0x7B, 0x53, 0x60,  // backspace return tab escape left keypad-1 F5
    ]
    private static let maximumUndrainedMicroseconds: UInt64 = 100_000

    private var random: SplitMix64
    private let includePostingBreaks: Bool
    private var pressed: [UInt16] = []
    private var shift = false
    private var control = false
    private var secureOn = false
    private var permissionOn = true
    private var postingOn = true
    private var undrained: UInt64 = 0

    init(seed: UInt64, includePostingBreaks: Bool) {
        random = SplitMix64(seed: seed)
        self.includePostingBreaks = includePostingBreaks
    }

    mutating func sequence(length: Int) -> [RandomEventGenerator.Step] {
        var steps: [RandomEventGenerator.Step] = []
        while steps.count < length { steps += next() }
        return steps
    }

    private mutating func next() -> [RandomEventGenerator.Step] {
        let roll = random.below(100)
        switch roll {
        case 0..<37: return [.key(keyEvent())]
        case 37..<39: return chord()
        case 39..<40: return [random.chance(50) ? .settingsChange : .inputSourceChange]
        case 40..<44: return modifierChange()
        case 44..<46: return controlShiftTap()
        case 46..<49: return [.key(Self.event(.leftMouseDown, keyCode: 0, flags: 0))]
        case 49..<51: return [.key(Self.event(.scrollWheel, keyCode: 0, flags: 0))]
        case 51..<52:
            let kind: RawKeyEvent.Kind = random.chance(50) ? .tapDisabledByTimeout : .tapDisabledByUserInput
            return [.key(Self.event(kind, keyCode: 0, flags: 0))]
        case 52..<56: return [.focusChange]
        case 56..<58:
            secureOn.toggle()
            return [.secureInput(secureOn)]
        case 58..<60:
            permissionOn.toggle()
            return [.permission(permissionOn)]
        case 60..<62 where includePostingBreaks:
            postingOn.toggle()
            return [.postingWorks(postingOn)]
        case 62..<76: return [.workerRuns(maxJobs: 1 + random.below(4))]
        case 76..<86:
            undrained = 0
            return [.tapDrains(maxEvents: 1 + random.below(4))]
        case 86..<87:
            // The worker stalls past the PLT-R314 liveness ceiling; the server is drained on both sides so no
            // echo waits there longer than the echo timeout.
            undrained = 0
            return [.tapDrains(maxEvents: Int.max), .advanceMicroseconds(160_000), .tapDrains(maxEvents: Int.max)]
        default:
            return advance()
        }
    }

    private mutating func advance() -> [RandomEventGenerator.Step] {
        let microseconds = UInt64(100 + random.below(5_000))
        undrained += microseconds
        guard undrained >= Self.maximumUndrainedMicroseconds else { return [.advanceMicroseconds(microseconds)] }
        undrained = 0
        return [.advanceMicroseconds(microseconds), .tapDrains(maxEvents: Int.max)]
    }

    private mutating func keyEvent() -> RawKeyEvent {
        if !pressed.isEmpty && random.chance(45) {
            let code = pressed.remove(at: random.below(pressed.count))
            return Self.event(.keyUp, keyCode: code, flags: flags)
        }
        if let held = pressed.last, random.chance(5) {  // autorepeat of the most recent key
            return Self.event(.keyDown, keyCode: held, flags: flags, autorepeat: true)
        }
        let code = Self.keyPool[random.below(Self.keyPool.count)]
        if !pressed.contains(code) { pressed.append(code) }
        var event = Self.event(.keyDown, keyCode: code, flags: flags)
        if random.chance(3) { event.userData = Int64(bitPattern: random.next() | 1) }  // another tool's data
        return event
    }

    private mutating func modifierChange() -> [RandomEventGenerator.Step] {
        if random.chance(50) {
            shift.toggle()
            return [.key(Self.event(.flagsChanged, keyCode: 0x38, flags: flags))]
        }
        control.toggle()
        return [.key(Self.event(.flagsChanged, keyCode: 0x3B, flags: flags))]
    }

    /// A Command or Option chord (PLT-R350): the modifier goes down, a pool key is pressed and released with
    /// it, the modifier goes up.
    private mutating func chord() -> [RandomEventGenerator.Step] {
        let command = random.chance(50)
        let modifierKey: UInt16 = command ? 0x37 : 0x3A
        let chordFlags = flags | (command ? 0x0010_0000 : 0x0008_0000)
        let code = Self.keyPool[random.below(Self.keyPool.count)]
        return [
            .key(Self.event(.flagsChanged, keyCode: modifierKey, flags: chordFlags)),
            .key(Self.event(.keyDown, keyCode: code, flags: chordFlags)),
            .key(Self.event(.keyUp, keyCode: code, flags: chordFlags)),
            .key(Self.event(.flagsChanged, keyCode: modifierKey, flags: flags)),
        ]
    }

    /// Press Control, press Shift, release both: the default toggle (PRD-R14), sometimes cancelled by a key.
    private mutating func controlShiftTap() -> [RandomEventGenerator.Step] {
        guard !shift && !control else { return modifierChange() }
        var steps: [RandomEventGenerator.Step] = []
        control = true
        steps.append(.key(Self.event(.flagsChanged, keyCode: 0x3B, flags: flags)))
        shift = true
        steps.append(.key(Self.event(.flagsChanged, keyCode: 0x38, flags: flags)))
        if random.chance(20) { steps.append(.key(Self.event(.scrollWheel, keyCode: 0, flags: flags))) }
        shift = false
        steps.append(.key(Self.event(.flagsChanged, keyCode: 0x38, flags: flags)))
        control = false
        steps.append(.key(Self.event(.flagsChanged, keyCode: 0x3B, flags: flags)))
        return steps
    }

    private var flags: UInt64 { (shift ? 0x0002_0000 : 0) | (control ? 0x0004_0000 : 0) }

    static func event(
        _ kind: RawKeyEvent.Kind, keyCode: UInt16, flags: UInt64, autorepeat: Bool = false
    ) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind, keyCode: KeyCode(rawValue: keyCode), flags: flags, autorepeat: autorepeat, keyboardType: 40,
            unicode: .empty, userData: 0, receivedAt: .zero)
    }
}
