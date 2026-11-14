// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pa's T5.5 report of 2026-11-14 end to end with fakes: Command+S opened TextEdit's save sheet, the name field took
// the focus without anyone being told, and `dduowngf` typed right away gave "ddường". The real tap thread, pipeline,
// focus tracker and inject worker of a started `InputHostController` (HostRig); one simulated field stands for the
// sheet's name field and receives every key. PLT-R340 amendment (late focus change), PLT-R389.

import AppModel
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

@Suite("Late focus change end to end (PLT-R340 amendment)")
@MainActor
struct LateFocusEndToEndTests {
    private static let sheetField = FocusAttributes(
        role: "AXTextField", subrole: nil, identifier: "saveAsName", domClasses: [], editable: true,
        ancestorRoles: ["AXSheet", "AXWindow"], documentURL: nil, windowTitle: nil)

    /// Command+S, the sheet's field takes the focus, the first "d" goes into it on the document's snapshot; the
    /// read the key asked for (PLT-R389) publishes the field before the second "d". Same process, readable, and the
    /// field shows "d" before the caret: the composition is kept and the word is "đường".
    @Test func commandSThenTypingInTheSheetGivesDuongT55() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.send(.keyDown, keyCode: 0x01, flags: Flag.command)  // Command+S
        rig.send(.keyUp, keyCode: 0x01, flags: Flag.command)
        rig.field.reset(text: "")  // the name field; its selected "Untitled" is replaced by the first key
        rig.ax.focus(pid: HostRig.editorPID, attributes: Self.sheetField, notify: nil, element: 2)
        rig.type("d")
        rig.settle()  // the first key's read has published the sheet's field
        #expect(rig.controller.currentFocus().field.identifier == "saveAsName")
        rig.type("duowngf")
        #expect(rig.field.text == "đường")
    }

    /// The first key did not reach the field that took the focus (it shows other text): the worker's check fails,
    /// the key passes as typed and the composition restarts, which gives what the hard boundary gave before.
    @Test func aFieldThatDoesNotShowTheTokenGetsTheHardBoundary() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.type("d")
        rig.field.reset(text: "Report")  // the "d" went elsewhere
        rig.ax.focus(pid: HostRig.editorPID, attributes: Self.sheetField, notify: nil, element: 2)
        rig.controller.focusTracker.revalidate()
        rig.settle()
        rig.type("duowngf")
        #expect(rig.field.text == "Reportdường")
    }
}
