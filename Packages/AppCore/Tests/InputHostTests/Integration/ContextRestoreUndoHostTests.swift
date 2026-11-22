// SPDX-License-Identifier: GPL-3.0-or-later
//
// REG-42 end to end (the product owner's report of 23/11/2026 on 1.1.0-beta.1, ENG-R706): the whole host under fakes
// with the shipped rules, the real engine and the bundled data. `Thanks Giving bar` and a space restore `bả` to `bar`
// (rule L10); Escape right after is consumed and the field shows `bả ` again; a second Escape passes; the strong
// collision signal reaches the learned memory, and the learning signal of a collision word never becomes a per-app
// entry (ENG-R862). In a terminal, whose rule turns the restore key off, Escape passes and the text stays.

import AppModel
import Foundation
import Injection
import TestSupport
import Testing

@testable import InputHost

@Suite("Undo of a context restore through the host (ENG-R706, REG-42)")
@MainActor
struct ContextRestoreUndoHostTests {
    static let terminalPID: Int32 = 6_262

    private func recorded(_ rig: HostRig) -> Int {
        rig.utility.sync {}
        return rig.store.store.collisionMemory.entryCount
    }

    private func pressEscape(_ rig: HostRig) -> TapVerdict? {
        let verdict = rig.send(.keyDown, keyCode: Key.escape)
        rig.send(.keyUp, keyCode: Key.escape)
        return verdict
    }

    @Test func escapeRightAfterTheEnglishRunRestoreGivesTheWordBack() async {
        let rig = HostRig(realResources: true)
        await rig.start()
        defer { rig.stop() }
        rig.type("Thanks Giving bar ")
        #expect(rig.field.text == "Thanks Giving bar ")
        #expect(pressEscape(rig) == .swallow)
        #expect(rig.field.text == "Thanks Giving bả ")
        // ENG-R702: the second press passes through (an Escape reaches the field as no text).
        #expect(pressEscape(rig) == .pass)
        #expect(rig.field.text == "Thanks Giving bả ")
        rig.type("voiws KT qua nhaf oongr owr Ohio chowi")
        #expect(rig.field.text == "Thanks Giving bả với KT qua nhà ổng ở Ohio chơi")
        rig.settle()
        // ENG-R864: the strong signal for the Vietnamese side reaches the memory; ENG-R862: `bar` is a collision word,
        // so its learning signal never becomes a per-app learned word.
        #expect(recorded(rig) >= 1)
        #expect(!rig.events.contains { if case .learningProposal = $0 { true } else { false } })
        let user = await rig.store.store.state.user
        #expect(user.learnedWords.isEmpty)
    }

    /// PLT-R353: the terminal rule turns the restore key off; Escape passes untouched and nothing is learned.
    @Test func whereTheRuleTurnsTheRestoreKeyOffEscapePasses() async {
        let rig = HostRig(realResources: true)
        await rig.start()
        defer { rig.stop() }
        rig.processes.add(FakeProcessIdentityProvider.process(pid: Self.terminalPID, bundle: "com.apple.Terminal"))
        rig.ax.focus(
            pid: Self.terminalPID,
            attributes: FocusAttributes(
                role: "AXTextArea", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
                documentURL: nil, windowTitle: nil),
            notify: nil, element: 0)
        rig.workspace.send(.applicationActivated(pid: Self.terminalPID))
        rig.settle()
        #expect(rig.controller.currentFocus().decision.rule?.rawValue == "terminal.default")
        #expect(rig.controller.currentFocus().decision.restoreHotkeyEnabled == false)
        rig.type("Thanks Giving bar ")
        #expect(rig.field.text == "Thanks Giving bar ")
        #expect(pressEscape(rig) == .pass)
        #expect(rig.field.text == "Thanks Giving bar ")
        rig.settle()
        #expect(recorded(rig) == 0)
    }
}
