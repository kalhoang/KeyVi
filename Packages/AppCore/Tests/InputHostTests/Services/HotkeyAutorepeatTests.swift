// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R14, PLT-R353: auto-repeat keyDowns never toggle and never restore. The pipeline guards toggles itself,
// but its restore path relies on the recogniser (W1-F1 request), so the guarantee is pinned here for every
// binding kind and over seeded random event streams.

import AppModel
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

private let space = KeyCode.space
private let keyA = KeyCode(rawValue: 0x00)
private let keyZ = KeyCode(rawValue: 0x06)
private let f5 = KeyCode(rawValue: 0x60)

/// One recogniser configuration and the keyDown each of its key bindings matches.
private struct Configuration: Sendable, CustomTestStringConvertible {
    let label: String
    let toggle: HotkeyBinding
    let restore: HotkeyBinding?
    /// keyDowns that match a key binding when not auto-repeated.
    let matching: [(key: KeyCode, modifiers: ModifierKeys, result: HotkeyResult)]
    var testDescription: String { label }
}

private let configurations: [Configuration] = [
    Configuration(
        label: "tap toggle, Escape restore", toggle: .defaultToggle, restore: .key(.escape),
        matching: [(.escape, [], .restoreCandidate)]),
    Configuration(
        label: "combo toggle, combo restore", toggle: .keyCombo(modifiers: [.control], keyCode: space),
        restore: .keyCombo(modifiers: [.option], keyCode: keyZ),
        matching: [(space, [.control], .toggleCombo), (keyZ, [.option], .restoreCandidate)]),
    Configuration(
        label: "combo toggle, F5 restore", toggle: .keyCombo(modifiers: [.command, .shift], keyCode: keyA),
        restore: .key(f5), matching: [(keyA, [.command, .shift], .toggleCombo), (f5, [.function], .restoreCandidate)]),
]

/// Drives any `HotkeyRecognizing` through the protocol only: pins `init(toggle:restore:)` and
/// `mutating func handle(_:) -> HotkeyResult`, the two members the pipeline calls (W1-F1 contract).
private func results<Recognizer: HotkeyRecognizing>(
    _ type: Recognizer.Type, _ configuration: Configuration, _ inputs: [HotkeyInput]
) -> [HotkeyResult] {
    var recognizer = Recognizer(toggle: configuration.toggle, restore: configuration.restore)
    return inputs.map { recognizer.handle($0) }
}

private func isAutorepeat(_ input: HotkeyInput) -> Bool {
    if case .keyDown(_, _, true, _) = input { return true }
    return false
}

/// A seeded stream mixing modifier presses, bound and unbound keys (half of them auto-repeated), key releases,
/// clicks and scrolls, with timestamps that keep some modifier taps under 500 ms.
private func randomStream(seed: UInt64, count: Int, configuration: Configuration) -> [HotkeyInput] {
    var generator = SeededGenerator(seed: seed)
    let modifierKeys: [(KeyCode, ModifierKeys)] = [
        (.control, [.control]), (.shift, [.shift]), (.option, [.option]), (.command, [.command]),
        (.rightCommand, [.command, .rightCommand]),
    ]
    let keys = configuration.matching.map(\.key) + [keyA, keyZ, space, .escape, f5]
    let modifierSets: [ModifierKeys] = [
        [], [.control], [.option], [.command, .shift], [.function], [.control, .shift],
    ]
    var time: UInt64 = 0
    var held: ModifierKeys = []
    return (0..<count).map { _ in
        time += UInt64.random(in: 1...120, using: &generator)
        switch UInt64.random(in: 0..<10, using: &generator) {
        case 0...2:
            let (key, bits) = modifierKeys.randomElement(using: &generator)!
            held = held.isDisjoint(with: bits) ? held.union(bits) : held.subtracting(bits)
            return .flagsChanged(keyCode: key, modifiers: held, at: ms(time))
        case 3...7:
            let matched = configuration.matching.randomElement(using: &generator)!
            let useMatch = Bool.random(using: &generator)
            let key = useMatch ? matched.key : keys.randomElement(using: &generator)!
            let modifiers = useMatch ? matched.modifiers : modifierSets.randomElement(using: &generator)!
            let autorepeat = Bool.random(using: &generator)
            return .keyDown(keyCode: key, modifiers: modifiers, autorepeat: autorepeat, at: ms(time))
        case 8: return .keyUp(keyCode: keys.randomElement(using: &generator)!, at: ms(time))
        default: return Bool.random(using: &generator) ? .pointerDown(at: ms(time)) : .scroll(at: ms(time))
        }
    }
}

@Suite("HotkeyRecognizer auto-repeat (PRD-R14, PLT-R353)")
struct HotkeyAutorepeatTests {
    /// Every key binding fires on a fresh keyDown and stays silent on its auto-repeats.
    @Test(arguments: configurations)
    fileprivate func boundKeysFireOnlyWithoutAutorepeat(_ configuration: Configuration) {
        for match in configuration.matching {
            let fresh = HotkeyInput.keyDown(
                keyCode: match.key, modifiers: match.modifiers, autorepeat: false, at: ms(0))
            let repeated = HotkeyInput.keyDown(
                keyCode: match.key, modifiers: match.modifiers, autorepeat: true, at: ms(30))
            let observed = results(HotkeyRecognizer.self, configuration, [fresh, repeated, repeated])
            #expect(observed == [match.result, HotkeyResult.none, HotkeyResult.none])
        }
    }

    /// Over seeded streams: an auto-repeat keyDown always yields `.none`, so never `.toggleCombo` or
    /// `.restoreCandidate`.
    @Test(arguments: configurations)
    fileprivate func autorepeatNeverTogglesOrRestoresInRandomStreams(_ configuration: Configuration) {
        for seed: UInt64 in 1...40 {
            let inputs = randomStream(seed: seed, count: 300, configuration: configuration)
            let observed = results(HotkeyRecognizer.self, configuration, inputs)
            for (input, result) in zip(inputs, observed) where isAutorepeat(input) {
                #expect(result == HotkeyResult.none, "seed \(seed)")
            }
            // The stream is not vacuous: fresh keyDowns of the bindings do fire.
            #expect(observed.contains(.toggleCombo) || observed.contains(.restoreCandidate), "seed \(seed)")
        }
    }

    /// Auto-repeats are invisible: removing them from a stream changes no other result, so they neither fire
    /// nor cancel a modifier tap in progress (PRD-R14 "ignores autorepeat").
    @Test(arguments: configurations)
    fileprivate func removingAutorepeatsChangesNoOtherResult(_ configuration: Configuration) {
        for seed: UInt64 in 100...130 {
            let inputs = randomStream(seed: seed, count: 300, configuration: configuration)
            let withRepeats = zip(inputs, results(HotkeyRecognizer.self, configuration, inputs))
                .filter { !isAutorepeat($0.0) }.map(\.1)
            let withoutRepeats = results(HotkeyRecognizer.self, configuration, inputs.filter { !isAutorepeat($0) })
            #expect(withRepeats == withoutRepeats, "seed \(seed)")
        }
    }
}
