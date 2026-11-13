// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Settings hotkey recorder (PRD-R15, PRD-R16, PRD-R18): any press order, modifier-only taps from the list only,
// right-side taps from the device bits, macOS conflicts accepted with a warning that names the feature.

import AppModel
import Foundation
import InputHost
import Testing

@testable import ShellCore

@Suite struct HotkeyRecorderModelTests {
    typealias Flags = HotkeyRecorderSession.Flags
    let space: UInt16 = 0x31
    let keyK: UInt16 = 0x28

    @Test func comboRecordedInAnyPressOrder_PRDR15() {
        // Space first, then Control: the old "must press Space before Control" bug is impossible.
        var session = HotkeyRecorderSession(role: .toggleMode)
        session.handle(.keyDown(keyCode: space, flags: 0, isRepeat: false))
        session.handle(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control | Flags.option))
        session.handle(.keyDown(keyCode: space, flags: Flags.control | Flags.option, isRepeat: true))  // ignored
        session.handle(.keyUp(keyCode: space))
        let state = session.handle(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: 0))
        #expect(
            state
                == .finished(
                    .keyCombo(modifiers: [.control, .option], keyCode: .space), conflict: .selectNextInputSource))
        #expect(session.finishedBinding == .keyCombo(modifiers: [.control, .option], keyCode: .space))
    }

    @Test func modifierTapsFromTheListAndRightSideKeys() {
        var session = HotkeyRecorderSession(role: .toggleMode)
        session.handle(.flagsChanged(keyCode: KeyCode.command.rawValue, flags: Flags.command | Flags.rightCommand))
        let right = session.handle(.flagsChanged(keyCode: KeyCode.rightCommand.rawValue, flags: 0))
        #expect(right == .finished(.modifierTap(.rightCommand), conflict: nil))

        var shift = HotkeyRecorderSession(role: .toggleMode)
        shift.handle(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control))
        shift.handle(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: Flags.control | Flags.shift))
        shift.handle(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: Flags.control))
        #expect(
            shift.handle(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: 0))
                == .finished(.modifierTap(.controlShift), conflict: nil))

        var unsupported = HotkeyRecorderSession(role: .toggleMode)
        unsupported.handle(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: Flags.shift))
        #expect(
            unsupported.handle(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: 0))
                == .rejected(.unsupportedModifierTap))
        #expect(unsupported.finishedBinding == nil)
    }

    @Test func modifierFlagsKeepTheSideOnlyWhenOnlyTheRightKeyIsHeld() {
        #expect(HotkeyRecorderSession.modifierKeys(Flags.option | Flags.rightOption) == [.option, .rightOption])
        #expect(HotkeyRecorderSession.modifierKeys(Flags.option | Flags.rightOption | Flags.leftOption) == [.option])
        #expect(HotkeyRecorderSession.modifierKeys(Flags.command | Flags.leftCommand) == [.command])
        #expect(HotkeyRecorderSession.modifierKeys(Flags.shift | Flags.control) == [.shift, .control])
        #expect(HotkeyRecorderSession.modifierKeys(0) == [])
    }

    @Test func restoreRoleAcceptsABareKeyButNoModifierTap_PRDR18() {
        var restore = HotkeyRecorderSession(role: .restoreLastWord)
        restore.handle(.keyDown(keyCode: KeyCode.escape.rawValue, flags: 0, isRepeat: false))
        #expect(restore.handle(.keyUp(keyCode: KeyCode.escape.rawValue)) == .finished(.key(.escape), conflict: nil))

        var tap = HotkeyRecorderSession(role: .restoreLastWord)
        tap.handle(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control | Flags.shift))
        #expect(
            tap.handle(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: 0)) == .rejected(.unsupportedModifierTap)
        )

        var toggle = HotkeyRecorderSession(role: .toggleMode)
        toggle.handle(.keyDown(keyCode: keyK, flags: 0, isRepeat: false))
        #expect(toggle.handle(.keyUp(keyCode: keyK)) == .rejected(.keyWithoutModifierForToggle))
    }

    @Test func messagesForEveryState() throws {
        let l = try Localizers()
        #expect(HotkeyRecorderText.status(.idle, role: .toggleMode, appName: "App", localizer: l.vi) == nil)
        #expect(
            HotkeyRecorderText.status(
                .recording(held: [], key: nil), role: .toggleMode, appName: "App", localizer: l.vi)
                == "Nhấn tổ hợp phím mới, rồi thả ra.")
        #expect(
            HotkeyRecorderText.status(
                .recording(held: [.control, .shift], key: nil), role: .toggleMode, appName: "App", localizer: l.vi)
                == "⌃⇧")
        #expect(
            HotkeyRecorderText.status(
                .recording(held: [.command], key: KeyCode(rawValue: keyK)), role: .toggleMode, appName: "App",
                localizer: l.vi)
                == "⌘K")
        #expect(
            HotkeyRecorderText.status(
                .finished(.defaultToggle, conflict: nil), role: .toggleMode, appName: "App", localizer: l.vi) == nil)
        let rejected = HotkeyRecorderText.status(
            .rejected(.unsupportedModifierTap), role: .toggleMode, appName: "App", localizer: l.vi)
        #expect(rejected?.contains("Control + Shift") == true)
        #expect(
            HotkeyRecorderText.rejectionText(.unsupportedModifierTap, role: .restoreLastWord)
                == .hotkeyRejectedRestoreModifierTap)
        #expect(
            HotkeyRecorderText.rejectionText(.keyWithoutModifierForToggle, role: .toggleMode)
                == .hotkeyRejectedKeyWithoutModifier)
    }

    @Test func conflictsAreAcceptedWithAWarningNamingTheFeature_PRDR16() throws {
        let l = try Localizers()
        let binding = HotkeyBinding.keyCombo(modifiers: [.command], keyCode: .space)
        #expect(HotkeyRecorder.conflict(for: binding) == .spotlight)
        let warning = HotkeyRecorderText.status(
            .finished(binding, conflict: .spotlight), role: .toggleMode, appName: "App", localizer: l.vi)
        #expect(
            warning
                == "macOS đang dùng tổ hợp này cho Spotlight. App vẫn lưu lựa chọn của bạn; xem hướng dẫn để tắt phím tắt đó của macOS."
        )
        for conflict in SystemShortcutConflict.allCases {
            let text = HotkeyRecorderText.conflictMessage(conflict, appName: "App", localizer: l.en)
            #expect(text.hasPrefix("macOS already uses this shortcut for "), "\(conflict)")
            #expect(!text.contains("settings.hotkey"), "\(conflict) has copy")
        }
        #expect(
            HotkeyRecorderText.helpURL(siteHost: "example.invalid", localizer: l.vi)?.absoluteString
                == "https://example.invalid/ho-tro/#phim-tat-macos")
        #expect(
            HotkeyRecorderText.helpURL(siteHost: "example.invalid", localizer: l.en)?.absoluteString
                == "https://example.invalid/en/support/#macos-shortcuts")
        #expect(HotkeyRecorderText.helpURL(siteHost: "", localizer: l.en) == nil)
    }

    @Test func currentBindingDisplay() throws {
        let l = try Localizers()
        #expect(HotkeyRecorderText.display(.defaultToggle, localizer: l.vi) == "⌃⇧")
        #expect(HotkeyRecorderText.display(nil, localizer: l.vi) == "Chưa đặt")
        #expect(HotkeyRecorderText.display(.key(.escape), localizer: l.en) == "⎋")
    }
}
