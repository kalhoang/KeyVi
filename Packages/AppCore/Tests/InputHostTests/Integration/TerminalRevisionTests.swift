// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R357 and PLT-R342 in terminals (retest of 16/11/2026, build 20261116a): in iTerm2 a lowercase `tar thuwr` at
// the start of a line stayed "tar thử". The engine's RV5 revision was right ("tả thử", ENG-R828), but the worker
// read the terminal's Accessibility text back, found it unlike "tar thử", and applied only the current token's
// part. A terminal's Accessibility text is its screen grid, an echo of the shell's line editor that can lag by a
// network round trip and whose caret need not be a UTF-16 offset of that text, so `terminal.default` (and the VS Code
// integrated terminal) never verify (`verifyReentry: never`): the guard is the tap's own history, which every
// navigation key, click, focus change and Return resets. Whole host under fakes with the shipped rules and the real
// engine (code context, `lineStartRevision`).

import AppModel
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

/// How a terminal's Accessibility text fails to vouch for the shell's line. Which one iTerm2 shows is not known
/// (its Accessibility tree on the product owner's Mac is off limits); the fix must hold for all of them.
enum TerminalScreen: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// Warp's documented behaviour: the caret is always reported at 0.
    case caretAtZero
    /// The whole session buffer (earlier lines, then a prompt with a double-width glyph) and a caret counted in
    /// screen cells: one past the text's UTF-16 offset, so the read before it comes back short.
    case cellCaretInSessionBuffer
    /// The screen draws the shell's echo late: the last letter is not on screen when the worker reads.
    case echoBehind
    /// Control: a readable field whose previous word is not what KeyVi typed (autocorrect), with a correct caret.
    case previousWordChanged
    /// Control: the Accessibility text is exactly the field.
    case faithful

    var testDescription: String { rawValue }

    static let unverifiable: [TerminalScreen] = [.caretAtZero, .cellCaretInSessionBuffer, .echoBehind]
}

/// Field access whose reads come from what a terminal would expose for the simulated line; writes are unavailable
/// (the terminal rule's strategy posts keys only).
struct TerminalScreenAccess: FocusedFieldAccess {
    static let earlierLines = "~/src\n"
    /// "✅" is one UTF-16 unit drawn in two cells.
    static let prompt = "✅ ~ % "

    let field: SimulatedTextField
    let screen: TerminalScreen

    private var shown: (value: String, caret: Int) {
        let text = field.text
        let caret = field.selection.location
        switch screen {
        case .caretAtZero, .faithful:
            return (text, caret)
        case .cellCaretInSessionBuffer:
            let prefix = Self.earlierLines + Self.prompt
            return (prefix + text, prefix.utf16.count + 1 + caret)
        case .echoBehind:
            let behind = String(text.dropLast())
            return (Self.prompt + behind, Self.prompt.utf16.count + behind.utf16.count)
        case .previousWordChanged:
            return (text.replacingOccurrences(of: "tar", with: "tag"), caret)
        }
    }

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        .success(Injection.TextRange(location: screen == .caretAtZero ? 0 : shown.caret, length: 0))
    }

    func caret(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldCaret> {
        guard case .success(let selection) = selectedRange(field, timeout: timeout) else { return .unavailable }
        return .success(FieldCaret(selection: selection, characterCount: shown.value.utf16.count))
    }

    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        let units = Array(shown.value.utf16)
        let start = min(max(0, range.location), units.count)
        let end = min(start + min(range.length, SimulatedTextField.maximumAXTextUnits), units.count)
        return .success(String(decoding: units[start..<end], as: UTF16.self))
    }

    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    {
        .unavailable
    }

    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        .unavailable
    }
}

@Suite("Revisions in terminals and code editors (PLT-R357, PLT-R342)")
@MainActor
struct TerminalRevisionTests {
    static let appPID: Int32 = 6_161
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C

    /// A host over the real engine with `bundle` focused in an `AXTextArea`, reads answered as `screen` shows them.
    private func rig(_ bundle: String, screen: TerminalScreen) async -> HostRig {
        let rig = HostRig(realResources: true, fieldAccess: { TerminalScreenAccess(field: $0, screen: screen) })
        await rig.start()
        rig.processes.add(FakeProcessIdentityProvider.process(pid: Self.appPID, bundle: bundle))
        focusTextArea(rig, element: 0, notify: false)
        rig.workspace.send(.applicationActivated(pid: Self.appPID))
        rig.settle()
        return rig
    }

    private func focusTextArea(_ rig: HostRig, element: UInt16, notify: Bool) {
        rig.ax.focus(
            pid: Self.appPID,
            attributes: FocusAttributes(
                role: "AXTextArea", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
                documentURL: nil, windowTitle: nil),
            notify: notify ? .focusedElementChanged : nil, element: element)
    }

    private func press(_ rig: HostRig, _ keyCode: UInt16) {
        rig.send(.keyDown, keyCode: keyCode)
        rig.send(.keyUp, keyCode: keyCode)
    }

    /// A click reaches the tap (a hard boundary, PLT-R340) and leaves the caret where it is.
    private func click(_ rig: HostRig) {
        guard let (handle, userInfo) = rig.echoLoop.route.current else {
            Issue.record("no tap installed")
            return
        }
        let event = RawKeyEvent(
            kind: .leftMouseDown, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false,
            keyboardType: PipelineFixtures.keyboardType, unicode: .empty, userData: 0, receivedAt: MachClock().now())
        _ = HostRig.deliverOnTap(event, handle: handle, userInfo: userInfo)
        rig.controller.worker.runUntilIdle()
    }

    private func rule(_ rig: HostRig) -> String? { rig.controller.currentFocus().decision.rule?.rawValue }

    /// The bug: whatever the terminal's Accessibility text shows, RV5 turns the line-start `tar` into "tả" once
    /// `thuwr` shows the line is Vietnamese. The revision deletes "ar thử" and inserts "ả thử" one character per
    /// event (`unicodeChunk` 1), then the Space is replayed.
    @Test(arguments: TerminalScreen.unverifiable)
    func aTerminalWhoseScreenCannotVerifyStillGetsTheLineStartRevision(_ screen: TerminalScreen) async {
        let rig = await rig("com.googlecode.iterm2", screen: screen)
        defer { rig.stop() }
        #expect(rule(rig) == "terminal.default")
        rig.type("tar thuwr")
        #expect(rig.field.text == "tar thử")
        let before = rig.poster.posted.count
        rig.type(" ")
        #expect(rig.field.text == "tả thử ")
        let downs = rig.poster.posted.dropFirst(before).compactMap { posted -> SyntheticKeyEvent? in
            guard case .synthetic(let event, _) = posted, event.isKeyDown else { return nil }
            return event
        }
        let deletes = downs.filter { $0.keyCode == .delete }
        let inserts = downs.filter { $0.keyCode != .delete }
        #expect(deletes.count == 6, "PLT-R357: at most the previous token, the space and the current display")
        #expect(inserts.map(\.unicode.string).joined() == "ả thử")
        #expect(inserts.allSatisfy { $0.unicode.string.count == 1 }, "unicodeChunk 1")
    }

    /// The guard that replaces the read-back: a navigation key between `tar ` and `thuwr` resets the history, so
    /// nothing behind the caret is rewritten.
    @Test func aNavigationKeyBetweenTheWordsPreventsTheRevision() async {
        let rig = await rig("com.googlecode.iterm2", screen: .caretAtZero)
        defer { rig.stop() }
        rig.type("tar ")
        press(rig, Self.leftArrow)
        press(rig, Self.rightArrow)
        rig.type("thuwr ")
        #expect(rig.field.text == "tar thử ")
    }

    /// A click between the words is a hard boundary too (PLT-R340): no revision.
    @Test func aClickBetweenTheWordsPreventsTheRevision() async {
        let rig = await rig("com.googlecode.iterm2", screen: .caretAtZero)
        defer { rig.stop() }
        rig.type("tar ")
        click(rig)
        rig.type("thuwr ")
        #expect(rig.field.text == "tar thử ")
    }

    /// A focus change between the words (another terminal tab) is a new focus generation: no revision.
    @Test func aFocusChangeBetweenTheWordsPreventsTheRevision() async {
        let rig = await rig("com.googlecode.iterm2", screen: .caretAtZero)
        defer { rig.stop() }
        rig.type("tar ")
        focusTextArea(rig, element: 1, notify: true)
        rig.settle()
        rig.type("thuwr ")
        #expect(rig.field.text == "tar thử ")
    }

    /// A code editor still verifies (PLT-R342 `whenReadable`): with a faithful field the revision applies; with the
    /// previous word changed under KeyVi (autocorrect) the read-back finds it and only the current token's part is
    /// applied, as before.
    @Test func aCodeEditorStillVerifiesTheRevision() async {
        let faithful = await rig("com.microsoft.VSCode", screen: .faithful)
        #expect(rule(faithful) == "editor.vscodeFamily")
        faithful.type("tar thuwr ")
        #expect(faithful.field.text == "tả thử ")
        faithful.stop()

        let changed = await rig("com.microsoft.VSCode", screen: .previousWordChanged)
        defer { changed.stop() }
        changed.type("tar thuwr ")
        #expect(changed.field.text == "tar thử ")
    }
}
