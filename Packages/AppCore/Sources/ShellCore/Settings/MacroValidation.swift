// SPDX-License-Identifier: GPL-3.0-or-later
//
// Macro editor validation (PRD-R29, ENG-R1101, ENG-R1103). `MacroValidator` (SettingsStore) gives the per-row
// reason; the engine's `MacroTable` stays authoritative and is run on the whole list before anything is saved,
// so the editor never stores a table the engine would reject. Expansions are stored in NFC (ENG-R1101).

public import AppModel
public import Foundation
public import SettingsStore
internal import VietnameseEngine

/// The editor sheet's content.
public struct MacroDraft: Sendable, Hashable {
    /// nil for a new macro (also after "Nhân bản").
    public var id: UUID?
    public var shortcut: String
    public var expansion: String
    public var adaptCase: Bool
    public var enabled: Bool

    public init(
        id: UUID? = nil, shortcut: String = "", expansion: String = "", adaptCase: Bool = true, enabled: Bool = true
    ) {
        self.id = id
        self.shortcut = shortcut
        self.expansion = expansion
        self.adaptCase = adaptCase
        self.enabled = enabled
    }

    public init(editing macro: StoredMacro) {
        self.init(
            id: macro.id, shortcut: macro.trigger, expansion: macro.expansion, adaptCase: macro.adaptCase,
            enabled: macro.enabled)
    }
}

/// Non-blocking advice shown under the shortcut field.
public enum MacroWarning: Sendable, Hashable {
    /// In Telex a digit is a word boundary, so `shorter` fires as soon as the digit after it is typed and `longer`
    /// (`shorter` + digits...) can never be completed. In VNI digits are tone keys, so both work.
    case telexDigitBoundary(longer: String, shorter: String)
}

public struct MacroDraftCheck: Sendable, Hashable {
    /// First blocking problem (PRD-R29), nil when the draft can be saved.
    public var issue: MacroRowIssue?
    public var warnings: [MacroWarning]
    public var canSave: Bool { issue == nil }
}

/// A problem the engine found in the whole table, with the trigger it concerns (row context).
public struct MacroTableProblem: Sendable, Hashable, Error {
    public var trigger: String
    public var issue: MacroRowIssue
}

public enum MacroDraftValidator {
    /// ENG-R1101: expansions are NFC text. Typed or pasted text may be decomposed (NFD from some apps).
    public static func normalizedExpansion(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// Checks `draft` against every other macro, enabled or not (enabling one later must stay valid).
    public static func check(_ draft: MacroDraft, among macros: [StoredMacro], method: TypingMethod) -> MacroDraftCheck
    {
        let others = macros.filter { $0.id != draft.id }
        let issue = MacroValidator.issue(
            shortcut: draft.shortcut, expansion: normalizedExpansion(draft.expansion), others: others)
        let warnings = method == .telex ? telexDigitWarnings(draft.shortcut, others: others.map(\.trigger)) : []
        return MacroDraftCheck(issue: issue, warnings: warnings)
    }

    static func telexDigitWarnings(_ shortcut: String, others: [String]) -> [MacroWarning] {
        guard !shortcut.isEmpty else { return [] }
        var warnings: [MacroWarning] = []
        for other in others where !other.isEmpty {
            if continuesWithDigit(shortcut, after: other) {
                warnings.append(.telexDigitBoundary(longer: shortcut, shorter: other))
            } else if continuesWithDigit(other, after: shortcut) {
                warnings.append(.telexDigitBoundary(longer: other, shorter: shortcut))
            }
        }
        return warnings
    }

    /// `longer` starts with `shorter` (ignoring case, ENG-R1101) and the next character is an ASCII digit.
    static func continuesWithDigit(_ longer: String, after shorter: String) -> Bool {
        let long = Array(longer.lowercased().unicodeScalars)
        let short = Array(shorter.lowercased().unicodeScalars)
        guard long.count > short.count, Array(long.prefix(short.count)) == short else { return false }
        return ("0"..."9").contains(long[short.count])
    }

    /// Runs the engine's own validation (ENG-R1101, ENG-R1103) on the list about to be saved.
    public static func engineProblem(in macros: [StoredMacro]) -> MacroTableProblem? {
        let entries = macros.map {
            MacroTable.Entry(trigger: $0.trigger, expansion: $0.expansion, adaptCase: $0.adaptCase)
        }
        do {
            _ = try MacroTable(entries)
            return nil
        } catch {
            // MacroTable.init throws only ValidationError.
            return (error as? MacroTable.ValidationError).map { problem(for: $0, macros: macros) }
        }
    }

    static func problem(for error: MacroTable.ValidationError, macros: [StoredMacro]) -> MacroTableProblem {
        switch error {
        case .emptyTrigger(let trigger): MacroTableProblem(trigger: trigger, issue: .emptyShortcut)
        case .triggerTooLong(let trigger): MacroTableProblem(trigger: trigger, issue: .shortcutTooLong)
        case .invalidTriggerCharacter(let trigger):
            MacroTableProblem(
                trigger: trigger,
                issue: trigger.unicodeScalars.contains { $0.properties.isWhitespace }
                    ? .shortcutHasWhitespace : .shortcutNotPrintableASCII)
        case .expansionTooLong(let trigger): MacroTableProblem(trigger: trigger, issue: .expansionTooLong)
        case .duplicateTrigger(let trigger):
            MacroTableProblem(trigger: trigger, issue: .duplicate(of: firstTrigger(matching: trigger, in: macros)))
        case .shadowedByShorterTrigger(let trigger, let shorter):
            MacroTableProblem(trigger: trigger, issue: .shadowedBy(shorter: shorter))
        }
    }

    /// The earlier entry with the same key (the engine reports the later one).
    private static func firstTrigger(matching trigger: String, in macros: [StoredMacro]) -> String {
        macros.first { $0.trigger.lowercased() == trigger.lowercased() }?.trigger ?? trigger
    }
}

/// Copy of macro problems (Macros table), always with the shortcut or line they concern.
public enum MacroIssueText {
    public static func text(_ issue: MacroRowIssue, shortcut: String, localizer: Localizer) -> String {
        switch issue {
        case .emptyShortcut: localizer.string(MacrosText.issueEmptyShortcut)
        case .emptyExpansion: localizer.string(MacrosText.issueEmptyExpansion)
        case .shortcutTooLong: localizer.string(MacrosText.issueShortcutTooLong)
        case .shortcutHasWhitespace: localizer.string(MacrosText.issueShortcutWhitespace)
        case .shortcutNotPrintableASCII: localizer.string(MacrosText.issueShortcutNotASCII)
        case .expansionTooLong: localizer.string(MacrosText.issueExpansionTooLong)
        case .shadowedBy(let shorter): localizer.format(MacrosText.issueShadowedBy, shortcut, shorter)
        case .shadows(let longer): localizer.format(MacrosText.issueShadows, shortcut, longer)
        case .duplicate(let other): localizer.format(MacrosText.issueDuplicate, other)
        case .malformedLine: localizer.string(MacrosText.issueMalformedLine)
        }
    }

    /// "Dòng 12: thiếu phần nội dung gõ tắt." for an imported row (PRD-R43).
    public static func lineText(_ row: MacroImportRow, localizer: Localizer) -> String {
        guard let reason = lineReason(row, localizer: localizer) else { return "" }
        return localizer.format(MacrosText.issueLine, row.line, reason)
    }

    /// The reason of an imported row as it continues a sentence after "Dòng 12:" (PRD-R43 draft: lower case).
    static func lineReason(_ row: MacroImportRow, localizer: Localizer) -> String? {
        row.issue.map { continuation(text($0, shortcut: row.shortcut, localizer: localizer), locale: localizer.locale) }
    }

    /// Lower-cases a leading capital that only starts the sentence ("Thiếu" -> "thiếu"); keeps acronyms ("ASCII").
    static func continuation(_ sentence: String, locale: Locale) -> String {
        guard let first = sentence.first, first.isUppercase else { return sentence }
        let rest = sentence.dropFirst()
        if let second = rest.first, second.isUppercase { return sentence }
        return String(first).lowercased(with: locale) + rest
    }

    /// "Gõ tắt "x": ..." for a problem in the saved list.
    public static func entryText(_ problem: MacroTableProblem, localizer: Localizer) -> String {
        localizer.format(
            MacrosText.issueEntry, problem.trigger, text(problem.issue, shortcut: problem.trigger, localizer: localizer)
        )
    }

    public static func warningText(_ warning: MacroWarning, localizer: Localizer) -> String {
        switch warning {
        case .telexDigitBoundary(let longer, let shorter):
            localizer.format(MacrosText.warningTelexDigit, longer, shorter)
        }
    }
}
