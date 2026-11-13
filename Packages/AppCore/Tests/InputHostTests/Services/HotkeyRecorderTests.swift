// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R15, PRD-R16, PRD-R18: the recorder captures chords in any press order and warns about macOS shortcuts.

import AppModel
import RealtimeSupport
import Testing

@testable import InputHost

private let space = KeyCode.space
private let tab = KeyCode.tab
private let ansiQ = KeyCode(rawValue: 0x0C)
private let ansiW = KeyCode(rawValue: 0x0D)
private let ansiA = KeyCode(rawValue: 0x00)
private let ansiK = KeyCode(rawValue: 0x28)

/// The physical key of each generic modifier, for building press sequences.
private func keyCode(of modifier: ModifierKeys) -> KeyCode {
    switch modifier {
    case .control: .control
    case .option: .option
    case .shift: .shift
    case .command: .command
    default: .function
    }
}

/// Presses `modifiers` in the given order, optionally `key` after `keyAfter` modifiers, then releases in
/// `releaseOrder` (indices into `modifiers`).
private func sequence(
    _ modifiers: [ModifierKeys], key: KeyCode? = nil, keyAfter: Int = 0, releaseOrder: [Int]? = nil
) -> [HotkeyInput] {
    var inputs: [HotkeyInput] = []
    var held: ModifierKeys = []
    for (index, modifier) in modifiers.enumerated() {
        if let key, index == keyAfter {
            inputs.append(.keyDown(keyCode: key, modifiers: held, autorepeat: false, at: ms(0)))
        }
        held.formUnion(modifier)
        inputs.append(.flagsChanged(keyCode: keyCode(of: modifier), modifiers: held, at: ms(0)))
    }
    if let key, keyAfter >= modifiers.count {
        inputs.append(.keyDown(keyCode: key, modifiers: held, autorepeat: false, at: ms(0)))
    }
    if let key { inputs.append(.keyUp(keyCode: key, at: ms(0))) }
    for index in releaseOrder ?? Array(modifiers.indices) {
        held.subtract(modifiers[index])
        inputs.append(.flagsChanged(keyCode: keyCode(of: modifiers[index]), modifiers: held, at: ms(0)))
    }
    return inputs
}

private func record(_ inputs: [HotkeyInput], role: HotkeyRole = .toggleMode, layout: LayoutTable? = nil)
    -> RecorderState
{
    var recorder = HotkeyRecorder(role: role, layout: layout)
    var state = RecorderState.idle
    for input in inputs { state = recorder.handle(input) }
    return state
}

private let twoModifierChords: [(ModifierTapChord, ModifierKeys, ModifierKeys)] = [
    (.controlShift, .control, .shift), (.commandShift, .command, .shift), (.optionShift, .option, .shift),
    (.controlOption, .control, .option),
]

@Suite("HotkeyRecorder (PRD-R15, PRD-R16)")
struct HotkeyRecorderTests {
    @Test func everyTwoModifierChordInAnyPressAndReleaseOrder() {
        for (chord, first, second) in twoModifierChords {
            for order in [[first, second], [second, first]] {
                for release in [[0, 1], [1, 0]] {
                    let state = record(sequence(order, releaseOrder: release))
                    #expect(state == .finished(.modifierTap(chord), conflict: nil), "\(chord) \(order) \(release)")
                }
            }
        }
    }

    @Test func rightSideOnlyChords() {
        let rightCommand: [HotkeyInput] = [
            .flagsChanged(keyCode: .rightCommand, modifiers: [.command, .rightCommand], at: ms(0)),
            .flagsChanged(keyCode: .rightCommand, modifiers: [], at: ms(10)),
        ]
        #expect(record(rightCommand) == .finished(.modifierTap(.rightCommand), conflict: nil))
        let rightOption: [HotkeyInput] = [
            .flagsChanged(keyCode: .rightOption, modifiers: [.option], at: ms(0)),
            .flagsChanged(keyCode: .rightOption, modifiers: [], at: ms(10)),
        ]
        #expect(record(rightOption) == .finished(.modifierTap(.rightOption), conflict: nil))
    }

    @Test func rightCommandWithShiftRecordsCommandShift() {
        let inputs: [HotkeyInput] = [
            .flagsChanged(keyCode: .rightCommand, modifiers: [.command, .rightCommand], at: ms(0)),
            .flagsChanged(keyCode: .shift, modifiers: [.command, .rightCommand, .shift], at: ms(5)),
            .flagsChanged(keyCode: .shift, modifiers: [.command, .rightCommand], at: ms(10)),
            .flagsChanged(keyCode: .rightCommand, modifiers: [], at: ms(15)),
        ]
        #expect(record(inputs) == .finished(.modifierTap(.commandShift), conflict: nil))
    }

    @Test func comboInAnyPressOrderFixesSpaceBeforeControl() {
        let spaceFirst = sequence([.control], key: space, keyAfter: 0)
        let controlFirst = sequence([.control], key: space, keyAfter: 1)
        let expected = RecorderState.finished(
            .keyCombo(modifiers: [.control], keyCode: space), conflict: .selectPreviousInputSource)
        #expect(record(spaceFirst) == expected)
        #expect(record(controlFirst) == expected)
    }

    @Test(arguments: [
        ([ModifierKeys.command], KeyCode.space, SystemShortcutConflict.spotlight),
        ([.control], .space, .selectPreviousInputSource),
        ([.control, .option], .space, .selectNextInputSource),
        ([.control, .command], .space, .characterViewer),
        ([.command], .tab, .appSwitcher),
        ([.command], KeyCode(rawValue: 0x0C), .quitApp),
        ([.command], KeyCode(rawValue: 0x0D), .closeWindow),
    ])
    func flagsTheSevenMacOSShortcutsButAcceptsThem(
        modifiers: [ModifierKeys], key: KeyCode, conflict: SystemShortcutConflict
    ) {
        let state = record(sequence(modifiers, key: key, keyAfter: modifiers.count))
        let binding = HotkeyBinding.keyCombo(modifiers: ModifierKeys(modifiers), keyCode: key)
        #expect(state == .finished(binding, conflict: conflict))
        #expect(HotkeyRecorder.conflict(for: binding) == conflict)
    }

    @Test func otherCombosHaveNoConflict() {
        #expect(HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.command, .shift], keyCode: space)) == nil)
        #expect(HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.option], keyCode: tab)) == nil)
        #expect(HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.command, .shift], keyCode: ansiQ)) == nil)
        #expect(HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.command], keyCode: ansiK)) == nil)
        #expect(HotkeyRecorder.conflict(for: .modifierTap(.controlShift)) == nil)
        #expect(HotkeyRecorder.conflict(for: .key(.escape)) == nil)
    }

    @Test func letterConflictsFollowTheLayout() {
        // AZERTY: the ABC "A" position types q, the ABC "Q" position types a.
        var entries = [LayoutEntry](repeating: .none, count: LayoutTable.keyCodeCount * 4)
        entries[Int(ansiA.rawValue) * 4] = .character("q")
        entries[Int(ansiQ.rawValue) * 4] = .character("a")
        entries[Int(ansiW.rawValue) * 4] = .character("Z")
        entries[0x06 * 4] = .character("W")
        let azerty = LayoutTable(source: sourceID("test.azerty"), keyboardType: 40, entries: entries)
        #expect(
            HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.command], keyCode: ansiA), layout: azerty) == .quitApp)
        #expect(HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.command], keyCode: ansiQ), layout: azerty) == nil)
        let closeKey = KeyCode(rawValue: 0x06)
        #expect(
            HotkeyRecorder.conflict(for: .keyCombo(modifiers: [.command], keyCode: closeKey), layout: azerty)
                == .closeWindow)
        #expect(
            record(sequence([.command], key: ansiA, keyAfter: 1), layout: azerty)
                == .finished(.keyCombo(modifiers: [.command], keyCode: ansiA), conflict: .quitApp))
    }

    @Test func toggleRefusesASingleKeyRestoreAcceptsIt() {
        let escape: [HotkeyInput] = [
            .keyDown(keyCode: .escape, modifiers: [], autorepeat: false, at: ms(0)),
            .keyUp(keyCode: .escape, at: ms(5)),
        ]
        #expect(record(escape) == .rejected(.keyWithoutModifierForToggle))
        #expect(record(escape, role: .restoreLastWord) == .finished(.key(.escape), conflict: nil))
    }

    @Test func restoreRefusesModifierOnlyTaps() {
        #expect(record(sequence([.control, .shift]), role: .restoreLastWord) == .rejected(.unsupportedModifierTap))
    }

    @Test func modifierOnlyChordsOutsideTheListAreRefused() {
        #expect(record(sequence([.command])) == .rejected(.unsupportedModifierTap))
        #expect(record(sequence([.control, .shift, .option])) == .rejected(.unsupportedModifierTap))
        let fn: [HotkeyInput] = [
            .flagsChanged(keyCode: .function, modifiers: [.function], at: ms(0)),
            .flagsChanged(keyCode: .function, modifiers: [], at: ms(5)),
        ]
        #expect(record(fn) == .rejected(.unsupportedModifierTap))  // Globe/fn not offered (PRD-R17)
    }

    @Test func reportsProgressWhileKeysAreHeld() {
        var recorder = HotkeyRecorder(role: .toggleMode)
        #expect(recorder.handle(.scroll(at: ms(0))) == .idle)
        #expect(recorder.handle(.flagsChanged(keyCode: .shift, modifiers: [], at: ms(0))) == .idle)
        #expect(
            recorder.handle(.flagsChanged(keyCode: .control, modifiers: [.control], at: ms(0)))
                == .recording(held: [.control], key: nil))
        #expect(
            recorder.handle(.keyDown(keyCode: space, modifiers: [.control], autorepeat: false, at: ms(1)))
                == .recording(held: [.control], key: space))
        #expect(
            recorder.handle(.keyDown(keyCode: space, modifiers: [.control], autorepeat: true, at: ms(2)))
                == .recording(held: [.control], key: space))
        #expect(recorder.handle(.pointerDown(at: ms(3))) == .recording(held: [.control], key: space))
        #expect(recorder.handle(.keyUp(keyCode: space, at: ms(4))) == .recording(held: [.control], key: space))
        #expect(
            recorder.handle(.flagsChanged(keyCode: .control, modifiers: [], at: ms(5)))
                == .finished(.keyCombo(modifiers: [.control], keyCode: space), conflict: .selectPreviousInputSource))
    }

    @Test func aNewPressAfterFinishingStartsANewRecording() {
        var recorder = HotkeyRecorder(role: .toggleMode)
        for input in sequence([.command]) { _ = recorder.handle(input) }
        var state = RecorderState.idle
        for input in sequence([.option, .shift]) { state = recorder.handle(input) }
        #expect(state == .finished(.modifierTap(.optionShift), conflict: nil))
        #expect(recorder.handle(.keyUp(keyCode: space, at: ms(9))) == state)
    }
}
