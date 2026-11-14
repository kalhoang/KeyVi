// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copy of the try-it screen (PRD-R40 screen 7; Pa, 2026-11-14, feedback item 4): each checklist item says exactly
// what to type, with the phrase quoted and set apart, and a second line with the keys to press for the selected
// input method; the toggle item names the shortcut set in Settings (D11) and what it does. The App's SwiftUI view
// lays the lines out; VoiceOver reads the state and both lines (PRD-R66, PRD-R67).

public import AppModel

/// A line with one part shown in a distinct style: the phrase to type, the keys to press or the shortcut.
public struct StyledLine: Sendable, Hashable {
    public var leading: String
    public var emphasis: String
    public var trailing: String

    public init(leading: String, emphasis: String, trailing: String) {
        self.leading = leading
        self.emphasis = emphasis
        self.trailing = trailing
    }

    public var plain: String { leading + emphasis + trailing }

    /// Placeholder put where the emphasised argument goes, then split on: a private-use character no copy holds.
    static let marker = "\u{E000}"

    /// `format` must place `marker` (passed as one of its arguments) where the emphasised part goes.
    init(splitting formatted: String, emphasis: String) {
        guard let range = formatted.range(of: Self.marker) else {
            self.init(leading: formatted, emphasis: "", trailing: "")
            return
        }
        self.init(
            leading: String(formatted[..<range.lowerBound]), emphasis: emphasis,
            trailing: String(formatted[range.upperBound...]))
    }
}

/// One checklist item: what to do, then the keys or the visible result.
public struct TryItItemContent: Sendable, Hashable {
    public var item: TryItChecklist.Item
    public var instruction: StyledLine
    public var detail: StyledLine

    public init(item: TryItChecklist.Item, instruction: StyledLine, detail: StyledLine) {
        self.item = item
        self.instruction = instruction
        self.detail = detail
    }

    /// "Chưa xong: <instruction>. <detail>": the state in words, never colour alone (PRD-R67).
    public func accessibilityLabel(done: Bool, localizer: Localizer) -> String {
        let text = instruction.plain + ". " + detail.plain
        return localizer.format(done ? OnboardingText.tryItItemDone : OnboardingText.tryItItemPending, text)
    }
}

public struct TryItScreenContent: Sendable, Hashable {
    public var title: String
    public var intro: String
    public var items: [TryItItemContent]

    /// `startMode` is the mode the window opened in: the toggle item says which language comes first.
    public init(localizer: Localizer, method: TypingMethod, toggleHotkey: HotkeyBinding, startMode: TypingMode) {
        title = localizer.string(OnboardingText.tryItTitle)
        intro = localizer.string(OnboardingText.tryItIntro)
        items = TryItChecklist.Item.allCases.map { item in
            Self.item(item, localizer: localizer, method: method, hotkey: toggleHotkey, startMode: startMode)
        }
    }

    private static func item(
        _ item: TryItChecklist.Item, localizer: Localizer, method: TypingMethod, hotkey: HotkeyBinding,
        startMode: TypingMode
    ) -> TryItItemContent {
        let marker = StyledLine.marker
        switch item {
        case .typeVietnamese:
            let phrase = localizer.string(OnboardingText.tryItTargetVietnamese)
            let methodName = localizer.string(
                method == .telex ? OnboardingText.methodTelexTitle : OnboardingText.methodVNITitle)
            let keys = localizer.string(
                method == .telex ? OnboardingText.tryItSequenceTelex : OnboardingText.tryItSequenceVNI)
            return TryItItemContent(
                item: item,
                instruction: StyledLine(
                    splitting: localizer.format(OnboardingText.tryItItemVietnamese, marker), emphasis: phrase),
                detail: StyledLine(
                    splitting: localizer.format(OnboardingText.tryItDetailVietnamese, methodName, marker),
                    emphasis: keys))
        case .typeEnglishWords:
            let words = localizer.string(OnboardingText.tryItTargetEnglish)
            return TryItItemContent(
                item: item,
                instruction: StyledLine(
                    splitting: localizer.format(OnboardingText.tryItItemEnglish, marker), emphasis: words),
                detail: StyledLine(
                    splitting: localizer.format(OnboardingText.tryItDetailEnglish, marker), emphasis: words))
        case .toggleAndBack:
            let fromVietnamese = startMode == .vietnamese
            let glyphs = [localizer.string(MenuText.hudVietnameseGlyph), localizer.string(MenuText.hudEnglishGlyph)]
            let (first, second) = fromVietnamese ? (glyphs[0], glyphs[1]) : (glyphs[1], glyphs[0])
            let instruction = localizer.format(
                fromVietnamese ? OnboardingText.tryItItemToggle : OnboardingText.tryItItemToggleFromEnglish, marker)
            let detail = localizer.format(OnboardingText.tryItDetailToggle, first, second)
            return TryItItemContent(
                item: item,
                instruction: StyledLine(
                    splitting: instruction, emphasis: ShortcutWords.string(for: hotkey, localizer: localizer)),
                detail: StyledLine(leading: detail, emphasis: "", trailing: ""))
        }
    }
}

/// A shortcut in words, as printed on the keys ("Control + Shift", "Command phải", "Control + Phím cách"), for copy
/// that tells a newcomer what to press. The Settings recorder keeps Apple's symbols (`HotkeyDisplay`).
enum ShortcutWords {
    /// Key legends of the modifiers in Apple's display order; they read the same in every interface language.
    private static let modifierNames: [(ModifierKeys, String)] = [
        (.function, "fn"), (.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command"),
    ]
    static let separator = " + "

    static func string(for binding: HotkeyBinding, localizer: Localizer) -> String {
        switch binding {
        case .modifierTap(.rightCommand): localizer.format(MenuText.hotkeyRight, name(of: .command))
        case .modifierTap(.rightOption): localizer.format(MenuText.hotkeyRight, name(of: .option))
        case .modifierTap(let chord): words(chord.modifiers).joined(separator: separator)
        case .keyCombo(let modifiers, let keyCode):
            (words(modifiers) + [HotkeyKeyNames.name(for: keyCode, localizer: localizer)]).joined(separator: separator)
        case .key(let keyCode): HotkeyKeyNames.name(for: keyCode, localizer: localizer)
        }
    }

    private static func words(_ modifiers: ModifierKeys) -> [String] {
        modifierNames.filter { modifiers.contains($0.0) }.map(\.1)
    }

    private static func name(of modifier: ModifierKeys) -> String {
        modifierNames.first { $0.0 == modifier }?.1 ?? ""
    }
}
