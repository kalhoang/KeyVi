// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R40 screen 7 (Pa, 2026-11-14, feedback item 4): every checklist item says exactly what to type, quoted and
// set apart, with the keys to press for the selected input method on a second line; the toggle item names the
// shortcut set in Settings and what it does. PRD-R66: VoiceOver reads the state and both lines.

import AppModel
import Foundation
import Testing
import VietnameseEngine

@testable import ShellCore

@Suite struct OnboardingTryItContentTests {
    let bundle: TemporaryAppBundle
    let vi: Localizer
    let en: Localizer

    init() throws {
        bundle = try TemporaryAppBundle(catalogs: [.onboarding, .menu])
        vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        en = Localizer(language: .english, appBundle: bundle.bundle)
    }

    func content(
        _ localizer: Localizer, method: TypingMethod = .telex, hotkey: HotkeyBinding = .defaultToggle,
        start: TypingMode = .vietnamese
    ) -> TryItScreenContent {
        TryItScreenContent(localizer: localizer, method: method, toggleHotkey: hotkey, startMode: start)
    }

    @Test func telexItemsQuoteThePhraseAndListTheKeysToPress() {
        let screen = content(vi)
        #expect(screen.title == "Thử gõ một chút")
        #expect(screen.intro == "Gõ vào ô bên dưới. Mỗi mục được đánh dấu khi bạn làm xong.")
        #expect(screen.items.map(\.item) == TryItChecklist.Item.allCases)
        let vietnamese = screen.items[0]
        #expect(vietnamese.instruction.plain == "Gõ cụm từ “Tiếng Việt có dấu”")
        #expect(vietnamese.instruction.emphasis == "Tiếng Việt có dấu")
        #expect(vietnamese.detail.plain == "Phím cần gõ (Telex): Tieengs Vieetj cos daaus")
        #expect(vietnamese.detail.emphasis == "Tieengs Vieetj cos daaus")
        let english = screen.items[1]
        #expect(english.instruction.plain == "Gõ các từ tiếng Anh “text user wifi”")
        #expect(english.instruction.emphasis == "text user wifi")
        #expect(english.detail.plain == "Phím cần gõ: text user wifi. Chữ phải giữ nguyên, không bị thêm dấu.")
        #expect(english.detail.emphasis == "text user wifi")
        let toggle = screen.items[2]
        #expect(
            toggle.instruction.plain
                == "Nhấn rồi thả Control + Shift để chuyển sang tiếng Anh, rồi làm lại một lần nữa để về tiếng Việt")
        #expect(toggle.instruction.emphasis == "Control + Shift")
        #expect(toggle.detail.plain == "Biểu tượng trên thanh menu đổi từ V sang E, rồi về lại V.")
    }

    @Test func vniShowsTheVNIKeys() {
        let detail = content(vi, method: .vni).items[0].detail
        #expect(detail.plain == "Phím cần gõ (VNI): Tie61ng Vie65t co1 da61u")
        #expect(detail.emphasis == "Tie61ng Vie65t co1 da61u")
    }

    @Test func englishInterfaceIsAFaithfulTranslation() {
        let screen = content(en)
        #expect(screen.title == "Try it out")
        #expect(screen.intro == "Type in the field below. Each item is ticked when you finish it.")
        #expect(screen.items[0].instruction.plain == "Type the phrase “Tiếng Việt có dấu”")
        #expect(screen.items[0].detail.plain == "Keys to press (Telex): Tieengs Vieetj cos daaus")
        #expect(screen.items[1].instruction.plain == "Type the English words “text user wifi”")
        #expect(
            screen.items[1].detail.plain
                == "Keys to press: text user wifi. The words must stay as typed, with no marks added."
        )
        #expect(
            screen.items[2].instruction.plain
                == "Press and release Control + Shift to switch to English, then do it again to go back to Vietnamese")
        #expect(screen.items[2].detail.plain == "The menu bar icon changes from V to E, then back to V.")
    }

    /// The toggle item names the shortcut the user set (D11), in words, whatever kind of binding it is, with the
    /// modifiers in Apple's order (fn, Control, Option, Shift, Command), as Apple writes "Shift-Command-5".
    @Test func theToggleItemNamesTheShortcutFromTheSettings() {
        func shortcut(_ binding: HotkeyBinding, _ localizer: Localizer) -> String {
            content(localizer, hotkey: binding).items[2].instruction.emphasis
        }
        #expect(shortcut(.modifierTap(.commandShift), vi) == "Shift + Command")
        #expect(shortcut(.modifierTap(.optionShift), vi) == "Option + Shift")
        #expect(shortcut(.modifierTap(.controlOption), vi) == "Control + Option")
        #expect(shortcut(.modifierTap(.rightCommand), vi) == "Command phải")
        #expect(shortcut(.modifierTap(.rightOption), en) == "Right Option")
        #expect(shortcut(.keyCombo(modifiers: [.control], keyCode: .space), vi) == "Control + Phím cách")
        #expect(
            shortcut(.keyCombo(modifiers: [.command, .shift, .option], keyCode: .space), en)
                == "Option + Shift + Command + Space")
        #expect(shortcut(.keyCombo(modifiers: [.function, .control], keyCode: .space), en) == "fn + Control + Space")
    }

    /// The checklist ticks when the mode leaves the starting mode and comes back, so a window that starts in English
    /// says so the other way round.
    @Test func startingInEnglishSwapsTheTwoLanguages() {
        let toggle = content(vi, start: .english).items[2]
        #expect(
            toggle.instruction.plain
                == "Nhấn rồi thả Control + Shift để chuyển sang tiếng Việt, rồi làm lại một lần nữa để về tiếng Anh")
        #expect(toggle.detail.plain == "Biểu tượng trên thanh menu đổi từ E sang V, rồi về lại E.")
    }

    /// PRD-R66, PRD-R67: the spoken label carries the state (never colour alone) and both lines.
    @Test func voiceOverReadsTheStateAndBothLines() {
        let item = content(vi).items[0]
        #expect(
            item.accessibilityLabel(done: false, localizer: vi)
                == "Chưa xong: Gõ cụm từ “Tiếng Việt có dấu”. Phím cần gõ (Telex): Tieengs Vieetj cos daaus")
        #expect(item.accessibilityLabel(done: true, localizer: vi).hasPrefix("Đã xong: Gõ cụm từ"))
    }

    /// The keys shown really type the phrase the checklist waits for, with the shipped engine (ENG-R102 NFC).
    @Test func theKeysShownTypeThePhraseTheChecklistWaitsFor() {
        for method in [TypingMethod.telex, .vni] {
            let screen = content(vi, method: method)
            let typed = Self.type(screen.items[0].detail.emphasis, method: method)
            #expect(typed == vi.string(OnboardingText.tryItTargetVietnamese), "\(method)")
            var checklist = TryItChecklist(
                vietnameseTarget: vi.string(OnboardingText.tryItTargetVietnamese),
                englishTarget: vi.string(OnboardingText.tryItTargetEnglish), startMode: .vietnamese)
            checklist.textChanged(typed)
            #expect(checklist.completed == [.typeVietnamese])
        }
        #expect(content(vi).items[1].detail.emphasis == vi.string(OnboardingText.tryItTargetEnglish))
    }

    /// A field fed by the engine alone: pass-through keys are appended, edits replace the end (ENG-R610).
    static func type(_ keys: String, method: TypingMethod) -> String {
        let inputMethod: InputMethod = method == .telex ? .telex(TelexOptions()) : .vni
        var session = Session(
            engine: Engine(
                configuration: EngineConfiguration(inputMethod: inputMethod, autoRestore: false, typoCorrection: false),
                resources: .empty))
        var text: [Character] = []
        for character in keys {
            switch session.handle(.key(KeyInput(character))).action {
            case .passThrough:
                text.append(character)
            case .edit(let edit, let thenPassThrough):
                text.removeLast(min(edit.deleteCount, text.count))
                text.append(contentsOf: edit.insert)
                if thenPassThrough { text.append(character) }
            }
        }
        return String(text)
    }
}
