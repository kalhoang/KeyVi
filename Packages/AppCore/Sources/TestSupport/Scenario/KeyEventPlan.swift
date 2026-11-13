// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Turns a key script into timed key events (02-platform.md 13.2): the keyboard driver posts them, the dry run
// only counts them. Timing profiles: normal 80 to 150 ms between keystrokes (uniform, seeded), fast 30 ms,
// burst 5 ms. Offsets are deterministic for a given seed so a failing run can be replayed exactly.

public import AppModel

extension Scenario.TimingProfile {
    /// Keystroke-to-keystroke interval bounds in nanoseconds (13.2).
    public var intervalRange: ClosedRange<UInt64> {
        switch self {
        case .normal: 80_000_000...150_000_000
        case .fast: 30_000_000...30_000_000
        case .burst: 5_000_000...5_000_000
        }
    }

    func hold(forInterval interval: UInt64) -> UInt64 { KeyEventPlan.hold(forInterval: interval) }
}

/// SplitMix64: a tiny deterministic generator for reproducible timing (not for security).
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// FNV-1a of a scenario id, mixed into the base seed so each scenario gets its own reproducible sequence.
    public static func seed(_ base: UInt64, scenario id: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return base ^ hash
    }
}

public struct PlannedKeyEvent: Sendable, Hashable {
    public enum Phase: Sendable, Hashable { case down, up }

    /// Nanoseconds after the start of the script.
    public var offset: UInt64
    public var keyCode: KeyCode
    public var phase: Phase
    /// Modifier keys travel as `flagsChanged` events, every other key as `keyDown`/`keyUp`.
    public var isFlagsChanged: Bool
    /// `CGEventFlags` raw value carried by the event (modifiers held after this event).
    public var flags: UInt64

    public init(offset: UInt64, keyCode: KeyCode, phase: Phase, isFlagsChanged: Bool, flags: UInt64) {
        self.offset = offset
        self.keyCode = keyCode
        self.phase = phase
        self.isFlagsChanged = isFlagsChanged
        self.flags = flags
    }
}

public struct KeyEventPlan: Sendable, Hashable {
    public var events: [PlannedKeyEvent]
    public var keystrokes: Int
    /// Offset of the last event in nanoseconds.
    public var durationNanoseconds: UInt64 { events.last?.offset ?? 0 }

    /// Plans `keys` with `profile`. Throws for an unknown key name.
    public static func make(
        keys: [String], profile: Scenario.TimingProfile, seed: UInt64
    ) throws(KeyScriptError) -> KeyEventPlan {
        try make(keys: keys, intervalRange: profile.intervalRange, seed: seed)
    }

    /// Plans `keys` with intervals drawn uniformly from `intervalRange` (nanoseconds); used directly by the C2
    /// measurement, which types at exactly 10 keys per second (8.1).
    public static func make(
        keys: [String], intervalRange: ClosedRange<UInt64>, seed: UInt64
    ) throws(KeyScriptError) -> KeyEventPlan {
        let strokes = try ScenarioKeys.strokes(keys)
        var generator = SeededGenerator(seed: seed)
        var events: [PlannedKeyEvent] = []
        events.reserveCapacity(strokes.count * 2)
        var start: UInt64 = 0
        for stroke in strokes {
            let interval = UInt64.random(in: intervalRange, using: &generator)
            events += Self.events(for: stroke, at: start, hold: Self.hold(forInterval: interval))
            start += interval
        }
        return KeyEventPlan(events: events, keystrokes: strokes.count)
    }

    /// Estimated duration bounds of a script of `keystrokes` keys, in nanoseconds (dry-run plans).
    public static func estimatedDuration(keystrokes: Int, profile: Scenario.TimingProfile) -> ClosedRange<UInt64> {
        let steps = UInt64(max(0, keystrokes - 1))
        let range = profile.intervalRange
        let hold = profile.hold(forInterval: range.lowerBound)
        return
            (steps * range.lowerBound + hold)...(steps * range.upperBound + profile.hold(forInterval: range.upperBound))
    }

    /// How long a key stays down: half the interval, at most 40 ms, so every event of a keystroke is posted
    /// before the next keystroke starts.
    static func hold(forInterval interval: UInt64) -> UInt64 { min(interval / 2, 40_000_000) }

    private static func events(for stroke: KeyStroke, at start: UInt64, hold: UInt64) -> [PlannedKeyEvent] {
        guard let modifier = stroke.modifier else {
            let flags = stroke.keyIsModifier ? Self.modifierFlags(stroke.keyCode) : 0
            return [
                PlannedKeyEvent(
                    offset: start, keyCode: stroke.keyCode, phase: .down, isFlagsChanged: stroke.keyIsModifier,
                    flags: flags),
                PlannedKeyEvent(
                    offset: start + hold, keyCode: stroke.keyCode, phase: .up, isFlagsChanged: stroke.keyIsModifier,
                    flags: 0),
            ]
        }
        let step = hold / 3
        let held = modifier.flags
        let keyFlags = stroke.keyIsModifier ? held | Self.modifierFlags(stroke.keyCode) : held
        return [
            PlannedKeyEvent(offset: start, keyCode: modifier.keyCode, phase: .down, isFlagsChanged: true, flags: held),
            PlannedKeyEvent(
                offset: start + step, keyCode: stroke.keyCode, phase: .down, isFlagsChanged: stroke.keyIsModifier,
                flags: keyFlags),
            PlannedKeyEvent(
                offset: start + 2 * step, keyCode: stroke.keyCode, phase: .up, isFlagsChanged: stroke.keyIsModifier,
                flags: held),
            PlannedKeyEvent(
                offset: start + hold, keyCode: modifier.keyCode, phase: .up, isFlagsChanged: true, flags: 0),
        ]
    }

    private static func modifierFlags(_ keyCode: KeyCode) -> UInt64 {
        ScenarioModifier.allCases.first { $0.keyCode == keyCode }?.flags ?? 0
    }
}
