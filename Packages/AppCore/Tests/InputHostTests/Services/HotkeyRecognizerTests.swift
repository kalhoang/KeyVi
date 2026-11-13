// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R14, PRD-R18, PLT-R353: toggle tap, combos and the restore candidate (contracts.md 10.2).

import AppModel
import RealtimeSupport
import Testing

@testable import InputHost

private let space = KeyCode.space
private let keyA = KeyCode(rawValue: 0x00)
private let f5 = KeyCode(rawValue: 0x60)

private func flags(_ key: KeyCode, _ modifiers: ModifierKeys, at time: UInt64) -> HotkeyInput {
    .flagsChanged(keyCode: key, modifiers: modifiers, at: ms(time))
}

private func down(_ key: KeyCode, _ modifiers: ModifierKeys = [], repeat autorepeat: Bool = false, at time: UInt64 = 0)
    -> HotkeyInput
{
    .keyDown(keyCode: key, modifiers: modifiers, autorepeat: autorepeat, at: ms(time))
}

/// Feeds every input and returns the results.
private func run(_ recognizer: inout HotkeyRecognizer, _ inputs: [HotkeyInput]) -> [HotkeyResult] {
    inputs.map { recognizer.handle($0) }
}

private func controlShiftTap(start: UInt64 = 0, release: UInt64 = 150) -> [HotkeyInput] {
    [
        flags(.control, [.control], at: start), flags(.shift, [.control, .shift], at: start + 40),
        flags(.control, [.shift], at: release - 10), flags(.shift, [], at: release),
    ]
}

@Suite("HotkeyRecognizer (PRD-R14)")
struct HotkeyRecognizerTests {
    @Test func controlShiftTapTogglesOnReleaseOfTheLastModifierOnly() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        #expect(run(&recognizer, controlShiftTap()) == [.none, .none, .none, .toggleTap])
    }

    @Test func tapWorksInAnyPressAndReleaseOrder() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        let inputs = [
            flags(.shift, [.shift], at: 0), flags(.control, [.control, .shift], at: 30),
            flags(.shift, [.control], at: 90), flags(.control, [], at: 120),
        ]
        #expect(run(&recognizer, inputs).last == HotkeyResult.toggleTap)
        #expect(run(&recognizer, controlShiftTap(start: 1_000, release: 1_200)).last == HotkeyResult.toggleTap)
    }

    @Test(arguments: [
        down(keyA, [.control, .shift], at: 60), .pointerDown(at: ms(60)), .scroll(at: ms(60)),
    ])
    func keyClickOrScrollDuringTheHoldCancels(interruption: HotkeyInput) {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        var inputs = controlShiftTap()
        inputs.insert(interruption, at: 2)
        #expect(!run(&recognizer, inputs).contains(.toggleTap))
        // The next clean tap works again.
        #expect(run(&recognizer, controlShiftTap(start: 1_000, release: 1_100)).last == HotkeyResult.toggleTap)
    }

    @Test func holdingLongerThan500MillisecondsCancels() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        #expect(run(&recognizer, controlShiftTap(release: 501)).last == HotkeyResult.none)
        #expect(run(&recognizer, controlShiftTap(start: 1_000, release: 1_500)).last == HotkeyResult.toggleTap)
    }

    @Test func holdOver500MillisecondsCancelsEvenBeforeTheRelease() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        let inputs = [
            flags(.control, [.control], at: 0), flags(.shift, [.control, .shift], at: 600),
            flags(.shift, [.control], at: 610), flags(.control, [], at: 620),
        ]
        #expect(!run(&recognizer, inputs).contains(.toggleTap))
    }

    @Test func chordUsedWithAnotherModifierNeverToggles() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        let inputs = [
            flags(.control, [.control], at: 0), flags(.shift, [.control, .shift], at: 20),
            flags(.command, [.control, .shift, .command], at: 40), flags(.command, [.control, .shift], at: 60),
            flags(.shift, [.control], at: 80), flags(.control, [], at: 100),
        ]
        #expect(!run(&recognizer, inputs).contains(.toggleTap))
    }

    @Test func pressingOnlyPartOfTheChordDoesNotToggle() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        #expect(run(&recognizer, [flags(.control, [.control], at: 0), flags(.control, [], at: 50)]) == [.none, .none])
    }

    @Test func capsLockDuringTheHoldCancels() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        var inputs = controlShiftTap()
        inputs.insert(flags(.capsLock, [.control, .shift], at: 60), at: 2)
        #expect(!run(&recognizer, inputs).contains(.toggleTap))
    }

    @Test func autorepeatIsIgnored() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: .key(.escape))
        var inputs = controlShiftTap()
        inputs.insert(down(keyA, [.control, .shift], repeat: true, at: 60), at: 2)
        #expect(run(&recognizer, inputs).last == HotkeyResult.toggleTap)
        #expect(recognizer.handle(down(.escape, repeat: true)) == HotkeyResult.none)

        var combo = HotkeyRecognizer(toggle: .keyCombo(modifiers: [.control], keyCode: space), restore: nil)
        #expect(combo.handle(down(space, [.control])) == .toggleCombo)
        #expect(combo.handle(down(space, [.control], repeat: true)) == HotkeyResult.none)
    }

    @Test func rightCommandTapUsesTheSideOfTheKey() {
        var recognizer = HotkeyRecognizer(toggle: .modifierTap(.rightCommand), restore: nil)
        let right = [flags(.rightCommand, [.command, .rightCommand], at: 0), flags(.rightCommand, [], at: 80)]
        #expect(run(&recognizer, right).last == HotkeyResult.toggleTap)
        // Only the generic bit reported: the keycode identifies the right key.
        let genericOnly = [flags(.rightCommand, [.command], at: 1_000), flags(.rightCommand, [], at: 1_080)]
        #expect(run(&recognizer, genericOnly).last == HotkeyResult.toggleTap)
        let left = [flags(.command, [.command], at: 2_000), flags(.command, [], at: 2_080)]
        #expect(run(&recognizer, left).last == HotkeyResult.none)
    }

    @Test func rightOptionTap() {
        var recognizer = HotkeyRecognizer(toggle: .modifierTap(.rightOption), restore: nil)
        let right = [flags(.rightOption, [.option, .rightOption], at: 0), flags(.rightOption, [], at: 80)]
        #expect(run(&recognizer, right).last == HotkeyResult.toggleTap)
    }

    @Test func commandShiftAcceptsTheRightCommandKey() {
        var recognizer = HotkeyRecognizer(toggle: .modifierTap(.commandShift), restore: nil)
        let inputs = [
            flags(.rightCommand, [.command, .rightCommand], at: 0),
            flags(.shift, [.command, .rightCommand, .shift], at: 20), flags(.shift, [.command, .rightCommand], at: 60),
            flags(.rightCommand, [], at: 80),
        ]
        #expect(run(&recognizer, inputs).last == HotkeyResult.toggleTap)
    }

    @Test func comboIsConsumedOnlyWithExactlyItsModifiers() {
        var recognizer = HotkeyRecognizer(
            toggle: .keyCombo(modifiers: [.control, .option], keyCode: space), restore: nil)
        #expect(recognizer.handle(down(space, [.control, .option])) == .toggleCombo)
        #expect(recognizer.handle(down(space, [.control, .option, .rightOption])) == .toggleCombo)
        #expect(recognizer.handle(down(space, [.control])) == HotkeyResult.none)
        #expect(recognizer.handle(down(space, [.control, .option, .shift])) == HotkeyResult.none)
        #expect(recognizer.handle(down(keyA, [.control, .option])) == HotkeyResult.none)
        #expect(recognizer.handle(.keyUp(keyCode: space, at: ms(0))) == HotkeyResult.none)
    }

    @Test func comboBindingIgnoresModifierOnlyEvents() {
        var recognizer = HotkeyRecognizer(toggle: .keyCombo(modifiers: [.control], keyCode: space), restore: nil)
        #expect(run(&recognizer, controlShiftTap()) == [.none, .none, .none, .none])
    }

    @Test func restoreCandidateOnlyForItsBinding() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: .key(.escape))
        #expect(recognizer.handle(down(.escape)) == .restoreCandidate)
        #expect(recognizer.handle(down(.escape, [.command])) == HotkeyResult.none)
        #expect(recognizer.handle(down(keyA)) == HotkeyResult.none)

        var unset = HotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        #expect(unset.handle(down(.escape)) == HotkeyResult.none)

        var combo = HotkeyRecognizer(toggle: .defaultToggle, restore: .keyCombo(modifiers: [.option], keyCode: keyA))
        #expect(combo.handle(down(keyA, [.option])) == .restoreCandidate)
        #expect(combo.handle(down(keyA)) == HotkeyResult.none)
    }

    @Test func restoreBindingAsModifierTapIsIgnored() {
        var recognizer = HotkeyRecognizer(
            toggle: .keyCombo(modifiers: [.control], keyCode: space), restore: .modifierTap(.controlShift))
        #expect(!run(&recognizer, controlShiftTap()).contains(.restoreCandidate))
    }

    @Test func toggleComboWinsOverAnIdenticalRestoreBinding() {
        let binding = HotkeyBinding.keyCombo(modifiers: [.control], keyCode: space)
        var recognizer = HotkeyRecognizer(toggle: binding, restore: binding)
        #expect(recognizer.handle(down(space, [.control])) == .toggleCombo)
    }

    @Test func functionFlagOnFunctionKeysDoesNotBreakAKeyBinding() {
        var recognizer = HotkeyRecognizer(toggle: .defaultToggle, restore: .key(f5))
        #expect(recognizer.handle(down(f5, [.function])) == .restoreCandidate)
    }

    @Test func maximumTapDurationIs500Milliseconds() {
        #expect(HotkeyRecognizer.maximumTapDuration == .milliseconds(500))
        #expect(HotkeyChordTracker.maximumTapNanoseconds == 500_000_000)
    }
}
