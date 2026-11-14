// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R405 for edits triggered by Return, keypad Enter, Tab, Space and Escape: the commit edit at a boundary (the
// ENG-R532 spelling of `thuở`, an English restore, a macro expansion, ENG-R803, ENG-R1103) and a restore on the
// Escape hotkey insert on the keycode of a letter of the edit, never on the trigger's own keycode. Chromium (so every
// Electron chat app) and WebKit derive the DOM `code` and, for a non-ASCII character, the legacy `keyCode` from the
// virtual keycode: a Unicode `ở` posted on `kVK_Return` reaches a composer that sends on `keyCode` 13 as one more
// Return, so the message leaves before the word is finished, and on `kVK_Tab` it moves the focus. The trigger itself
// still reaches the app afterwards, on its own keycode, exactly once (the replay the pipeline queues behind the edit,
// ADR 0308). Every strategy that posts Unicode events (`backspaceReplace`, `selectReplace`) follows the rule.

import AppModel
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

/// A chat composer that acts on the keycode first, like a web editor reading `keydown` `code` or `keyCode`:
/// Backspace deletes one character (or the selection), Return sends (the transcript shows `<send>`), Tab moves the
/// focus away (later keys are lost), Escape cancels (`<esc>`), Space types a space whatever its Unicode string, and
/// Shift+Left Arrow extends the selection. Any other key types its Unicode string over the selection.
private final class KeyCodeFirstComposer: @unchecked Sendable {
    private struct State {
        var characters: [Character]
        var selected = 0
        var focused = true
        var sends = 0
        var focusMoves = 0
    }

    private let lock: Mutex<State>

    init(text: String) { lock = Mutex(State(characters: Array(text))) }

    var text: String { lock.withLock { String($0.characters) } }
    var sends: Int { lock.withLock { $0.sends } }
    var focusMoves: Int { lock.withLock { $0.focusMoves } }

    func apply(_ posted: FakeEventPoster.Posted) {
        switch posted {
        case .synthetic(let event, _):
            guard event.isKeyDown else { return }
            press(event.keyCode, flags: event.flags, text: event.unicode.string)
        case .replay(let record, _):
            guard record.kind == .keyDown else { return }
            press(record.keyCode, flags: record.flags, text: record.unicode.string)
        }
    }

    private func press(_ keyCode: KeyCode, flags: UInt64, text: String) {
        lock.withLock { state in
            guard state.focused else { return }
            switch keyCode {
            case .delete:
                let count = max(state.selected, 1)
                state.characters.removeLast(min(count, state.characters.count))
                state.selected = 0
            case .returnKey, .keypadEnter:
                state.characters += Array("<send>")
                state.sends += 1
            case .tab:
                state.focused = false
                state.focusMoves += 1
            case .escape: state.characters += Array("<esc>")
            case .space: Self.type(" ", into: &state)
            case .leftArrow where flags & SyntheticKeys.shiftFlag != 0:
                state.selected = min(state.selected + 1, state.characters.count)
            default: Self.type(text, into: &state)
            }
        }
    }

    private static func type(_ text: String, into state: inout State) {
        state.characters.removeLast(state.selected)
        state.selected = 0
        state.characters += Array(text)
    }
}

/// Triggers whose keycode an app may act on, with the physical event the pipeline replays after the edit.
enum CommitTrigger: String, CaseIterable, Sendable {
    case returnKey, keypadEnter, tab, space

    var keyCode: KeyCode {
        switch self {
        case .returnKey: .returnKey
        case .keypadEnter: .keypadEnter
        case .tab: .tab
        case .space: .space
        }
    }

    var record: KeyEventRecord {
        let character: String =
            switch self {
            case .returnKey, .keypadEnter: "\r"
            case .tab: "\t"
            case .space: " "
            }
        return KeyEventRecord(
            kind: .keyDown, keyCode: keyCode, flags: 0, autorepeat: false, keyboardType: 40,
            unicode: InlineUTF16(character) ?? .empty, receivedAt: Fixture.start, isProbe: false)
    }
}

@Suite struct CommitTriggerKeyCodeTests {
    /// `kVK_ANSI_U`: the layout key of `u`, the first character of the insertion `uở` that the layout types.
    static let letterU = KeyCode(rawValue: 0x20)

    private static func rig(composer: KeyCodeFirstComposer, field: String) -> WorkerRig {
        WorkerRig(field: SimulatedTextField(text: field), poster: FakeEventPoster { composer.apply($0) })
    }

    /// ENG-R532 at the trigger: the field shows `thưở`, the commit spelling is `thuở` (delete `ưở`, insert `uở`
    /// after the PLT-R402 trim), and the trigger follows as a replay.
    private static func commit(
        _ trigger: CommitTrigger, strategy: InjectionStrategy, composer: KeyCodeFirstComposer,
        parameters: InjectionParameters = .defaults
    ) -> WorkerRig {
        let rig = Self.rig(composer: composer, field: "thưở")
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 4, replaced: "thưở", insertion: "thuở",
                plan: Fixture.plan(strategy, parameters: parameters), trigger: nil,
                keyCodes: JobKeyCodes(
                    trigger: trigger.keyCode, firstCharacter: Self.letterU, paste: KeyCode(rawValue: 0x09)))
        }
        rig.pushReplay(trigger.record)
        rig.run()
        return rig
    }

    private static func expectedText(after trigger: CommitTrigger) -> String {
        switch trigger {
        case .returnKey, .keypadEnter: "thuở<send>"
        case .tab: "thuở"
        case .space: "thuở "
        }
    }

    @Test(arguments: CommitTrigger.allCases, [InjectionStrategy.backspaceReplace, .selectReplace])
    func aCommitEditNeverInsertsOnItsTriggerKeycodePLTR405(trigger: CommitTrigger, strategy: InjectionStrategy) {
        let composer = KeyCodeFirstComposer(text: "thưở")
        let rig = Self.commit(trigger, strategy: strategy, composer: composer)
        let insertions = rig.poster.posted.keyDowns.filter { $0.unicode.count > 0 }
        #expect(insertions.map(\.unicode.string) == ["u", "ở"])
        #expect(insertions.allSatisfy { $0.keyCode == Self.letterU })
        #expect(composer.text == Self.expectedText(after: trigger))
        #expect(composer.sends == (trigger == .returnKey || trigger == .keypadEnter ? 1 : 0))
        #expect(composer.focusMoves == (trigger == .tab ? 1 : 0))
    }

    /// The trigger reaches the app after the whole edit, on its own keycode, exactly once (P0-3, ADR 0308).
    @Test(arguments: CommitTrigger.allCases, [InjectionStrategy.backspaceReplace, .selectReplace])
    func theTriggerFollowsTheEditOnceOnItsOwnKeycode(trigger: CommitTrigger, strategy: InjectionStrategy) throws {
        let composer = KeyCodeFirstComposer(text: "thưở")
        let rig = Self.commit(trigger, strategy: strategy, composer: composer)
        let posted = rig.poster.posted
        let onTrigger = posted.indices.filter { index in
            switch posted[index] {
            case .synthetic(let event, _): event.isKeyDown && event.keyCode == trigger.keyCode
            case .replay(let record, _): record.kind == .keyDown && record.keyCode == trigger.keyCode
            }
        }
        #expect(onTrigger.count == 1)
        let index = try #require(onTrigger.first)
        #expect(posted[index].replayed == trigger.record, "the physical key, replayed as it was")
        #expect(index == posted.count - 1, "after every synthetic key of the edit")
    }

    /// PLT-R421: a placeholder that clears an inline suggestion rides the letter keycode too.
    @Test(arguments: CommitTrigger.allCases)
    func thePlaceholderRidesTheLetterKeycode(trigger: CommitTrigger) {
        let composer = KeyCodeFirstComposer(text: "thưở")
        let parameters = Fixture.parameters { $0.inlineCompletion = .placeholder }
        let rig = Self.commit(trigger, strategy: .backspaceReplace, composer: composer, parameters: parameters)
        let synthetic = rig.poster.posted.keyDowns.filter { $0.unicode.count > 0 }
        #expect(synthetic.first?.unicode.string == "\u{200B}")
        #expect(synthetic.allSatisfy { $0.keyCode == Self.letterU })
        #expect(composer.text == Self.expectedText(after: trigger))
    }

    /// A macro at Return whose expansion holds no character the layout types (the pipeline found no letter): the
    /// insertion uses the A position, not Return.
    @Test(arguments: CommitTrigger.allCases)
    func withoutALetterTheInsertionUsesTheLetterFallback(trigger: CommitTrigger) {
        let composer = KeyCodeFirstComposer(text: "")
        let rig = Self.rig(composer: composer, field: "")
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 0, insertion: "Đà", kind: .macro, trigger: nil,
                keyCodes: JobKeyCodes(trigger: trigger.keyCode, firstCharacter: nil, paste: KeyCode(rawValue: 0x09)))
        }
        rig.run()
        let insertions = rig.poster.posted.keyDowns.filter { $0.unicode.count > 0 }
        #expect(insertions.map(\.unicode.string) == ["Đ", "à"])
        #expect(insertions.allSatisfy { $0.keyCode == SyntheticKeys.letterFallback })
        #expect(composer.text == "Đà")
    }

    /// A first-character keycode that is itself an action key (an expansion that starts with a space) is never
    /// used: Space, Return and Tab type their own action in a keycode-first app.
    @Test func anActionKeyIsNeverTheLetterKeycode() {
        for (trigger, first) in [(KeyCode.returnKey, KeyCode.space), (.space, .tab), (.tab, .returnKey)] {
            let job = Fixture.job(
                deleteCount: 0, insertion: " a", kind: .macro, trigger: nil,
                keyCodes: JobKeyCodes(trigger: trigger, firstCharacter: first))
            #expect(SyntheticKeys.unicodeKeyCode(for: job) == SyntheticKeys.letterFallback, "\(trigger) \(first)")
        }
        // With a character trigger, such a first character falls back to the trigger, as before.
        let period = KeyCode(rawValue: 0x2F)
        let job = Fixture.job(
            deleteCount: 0, insertion: " a", kind: .macro, trigger: nil,
            keyCodes: JobKeyCodes(trigger: period, firstCharacter: .space))
        #expect(SyntheticKeys.unicodeKeyCode(for: job) == period)
    }

    /// The restore hotkey (Escape by default, PLT-R353) with no layout key for the restored text: the A position,
    /// never `kVK_Escape`, which a composer reads as "cancel".
    @Test func aRestoreOnEscapeWithoutALetterAvoidsTheEscapeKeycode() {
        let composer = KeyCodeFirstComposer(text: "việt")
        let rig = Self.rig(composer: composer, field: "việt")
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 4, replaced: "việt", insertion: "vieejt", kind: .restore, trigger: nil,
                keyCodes: JobKeyCodes(trigger: .escape, firstCharacter: nil))
        }
        rig.run()
        #expect(rig.poster.posted.keyDowns.allSatisfy { $0.keyCode != .escape })
        #expect(composer.text == "vieejt")
    }

    /// The table of keys whose keycode carries an action (PLT-R405): Backspace, Return, keypad Enter, Tab, Space and
    /// Escape. Letters, digits and punctuation keys are not among them.
    @Test func theActionKeys() {
        let actions: [KeyCode] = [.delete, .returnKey, .keypadEnter, .tab, .space, .escape]
        #expect(actions.allSatisfy(JobKeyCodes.isActionKey))
        let characters = [0x00, 0x20, 0x12, 0x2F, 0x2B, 0x21].map { KeyCode(rawValue: $0) }
        #expect(!characters.contains(where: JobKeyCodes.isActionKey))
    }
}
