// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// A small deterministic pseudo-random generator (SplitMix64) so that property tests and fuzz drivers
/// replay identically from a seed (ENG-T33). Not for anything but tests.
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
}

/// Random event streams over the alphabet of spec 13.6, weighted towards keys that compose so that
/// tokens are long enough to exercise transforms, relocation, escapes and Backspace.
public enum RandomEvents {
    /// Keys that compose often: vowels, Telex transform letters and common consonants.
    private static let composing: [Character] = Array("aeiouyowdsfrxjzaeouwnghctmpqkl")
    private static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits: [Character] = Array("0123456789")
    private static let boundaries: [Character] = [" ", " ", ".", ",", "'", "-", "@", "\n", "\t", "[", "]", "é", "ư"]
    private static let resets: [ResetReason] = [
        .cursorMoved, .pointerClicked, .focusChanged, .applicationChanged, .inputSourceChanged,
        .secureInputChanged, .eventTapReenabled, .shortcut, .forwardDelete, .modeToggled,
        .configurationChanged, .unknown,
    ]

    /// `count` events drawn from `generator`.
    public static func events(count: Int, using generator: inout SeededGenerator) -> [EngineEvent] {
        (0..<count).map { _ in event(using: &generator) }
    }

    public static func event(using generator: inout SeededGenerator) -> EngineEvent {
        let roll = Int.random(in: 0..<100, using: &generator)
        switch roll {
        case 0..<45:
            return key(composing.randomElement(using: &generator) ?? "a", uppercase: roll < 4)
        case 45..<63: return .key(KeyInput(letters.randomElement(using: &generator) ?? "a"))
        case 63..<77:
            return .key(KeyInput(digits.randomElement(using: &generator) ?? "1", fromKeypad: roll == 76))
        case 77..<85: return .key(KeyInput(boundaries.randomElement(using: &generator) ?? " "))
        case 85..<95: return .backspace
        case 95..<98: return .restoreToggle
        default: return .reset(resets.randomElement(using: &generator) ?? .unknown)
        }
    }

    private static func key(_ character: Character, uppercase: Bool) -> EngineEvent {
        .key(KeyInput(uppercase ? Character(character.uppercased()) : character))
    }
}
