// SPDX-License-Identifier: GPL-3.0-or-later
//
// The three English-restore user lists of the Typing pane: the two keep lists (ENG-R860), with the words learned per
// app (ENG-R862), and the never-correct list (1.1.0, PRD-R81, ENG-R1118); and the optional layout-to-mode binding of
// General > Advanced (PLT-R373).

public import AppModel
internal import Foundation
public import InputHost
public import SettingsStore

/// ENG-R860: "keep as typed" and "keep Vietnamese", keyed by lowercased raw keys; PRD-R81: "never correct", typed
/// words in lowercase letters (`NeverCorrectEntry`). Entries are user-authored text, allowed on disk (PLT-R901 a) and
/// never logged.
public enum UserWordList: String, Sendable, Hashable, CaseIterable {
    case keepAsTyped, keepVietnamese, neverCorrect

    public static let maxEntryLength = 32

    public enum AddResult: Sendable, Hashable {
        case added(Set<String>)
        case invalid
        case duplicate
    }

    public func entries(in settings: EffectiveSettings) -> [String] {
        switch self {
        case .keepAsTyped: settings.keepAsTyped.sorted()
        case .keepVietnamese: settings.keepVietnamese.sorted()
        case .neverCorrect: settings.neverCorrect.sorted()
        }
    }

    public func edit(_ entries: Set<String>) -> SettingsEdit {
        switch self {
        case .keepAsTyped: .keepAsTyped(entries)
        case .keepVietnamese: .keepVietnamese(entries)
        case .neverCorrect: .neverCorrect(entries)
        }
    }

    /// The catalog setting that names and explains the list (PRD-R25).
    public var settingItem: SettingItem {
        switch self {
        case .keepAsTyped: .keepAsTyped
        case .keepVietnamese: .keepVietnamese
        case .neverCorrect: .neverCorrect
        }
    }

    /// The list's entry field and add button (PRD-R66).
    public var fieldControl: SettingsControl {
        switch self {
        case .keepAsTyped: .keepAsTypedField
        case .keepVietnamese: .keepVietnameseField
        case .neverCorrect: .neverCorrectField
        }
    }

    public var addControl: SettingsControl {
        switch self {
        case .keepAsTyped: .keepAsTypedAdd
        case .keepVietnamese: .keepVietnameseAdd
        case .neverCorrect: .neverCorrectAdd
        }
    }

    /// The reason shown under the field when an entry is refused: raw keys for the keep lists, letters without
    /// marks for the never-correct list (PRD-R81).
    public var invalidMessage: SettingsText { self == .neverCorrect ? .neverCorrectInvalid : .listInvalid }

    /// `text` as an entry of this list, or nil when the list refuses it.
    public func normalizedEntry(_ text: String) -> String? {
        self == .neverCorrect ? NeverCorrectEntry.normalized(text) : Self.normalized(text)
    }

    /// `current` with `text` added under this list's rule.
    public func adding(_ text: String, to current: Set<String>) -> AddResult {
        guard let entry = normalizedEntry(text) else { return .invalid }
        guard !current.contains(entry) else { return .duplicate }
        return .added(current.union([entry]))
    }

    /// The keep lists' rule (ENG-R860): raw keys are printable ASCII without whitespace (the keys of the user's
    /// layout as typed), lowercased.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= maxEntryLength,
            trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        return trimmed
    }

    /// The keep lists' rule; `adding(_:to:)` on a list applies that list's rule.
    public static func adding(_ text: String, to current: Set<String>) -> AddResult {
        keepAsTyped.adding(text, to: current)
    }

    /// The SettingsStore keep list this pane list shows; nil for the never-correct list, which has no per-app
    /// entries.
    public var restoreList: RestoreList? {
        switch self {
        case .keepAsTyped: .keepAsTyped
        case .keepVietnamese: .keepVietnamese
        case .neverCorrect: nil
        }
    }

    /// One entry of the list: a global word (typed in Settings) or a word learned in one app (ENG-R862), which the
    /// pane shows with the app's name, resolved when shown and never stored.
    public struct Row: Sendable, Hashable, Identifiable {
        public var word: String
        /// nil for a global entry.
        public var learned: LearnedWord?

        public var id: String { learned.map { "app:\($0.app.rawValue):\($0.raw)" } ?? "global:" + word }
    }

    /// Every entry of this list, by word; a global entry comes before the same word learned in apps, and learned
    /// entries of one word are ordered by bundle identifier. The never-correct list holds global entries only.
    public func rows(in settings: UserSettings) -> [Row] {
        guard let restoreList else { return settings.neverCorrect.sorted().map { Row(word: $0, learned: nil) } }
        let global = settings.globalWords(in: restoreList).map { Row(word: $0, learned: nil) }
        let learned = settings.learnedWords.filter { $0.list == restoreList }.map { Row(word: $0.raw, learned: $0) }
        return (global + learned).sorted { lhs, rhs in
            (lhs.word, lhs.learned?.app.rawValue ?? "") < (rhs.word, rhs.learned?.app.rawValue ?? "")
        }
    }
}

/// PLT-R373 binding editor: only ASCII-capable layouts can be designated (others pause typing anyway, PLT-R371).
public struct LayoutBindingModel: Sendable, Hashable {
    public enum Assignment: String, Sendable, Hashable, CaseIterable {
        case none, vietnamese, english

        public var title: SettingsText {
            switch self {
            case .none: .layoutBindingNone
            case .vietnamese: .layoutBindingVietnamese
            case .english: .layoutBindingEnglish
            }
        }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public var id: InputSourceID
        public var name: String
        public var assignment: Assignment
    }

    public private(set) var binding: LayoutModeBinding
    public let rows: [Row]

    public init(binding: LayoutModeBinding, enabledSources: [InputSourceInfo]) {
        self.binding = binding
        let layouts = enabledSources.filter { $0.kind == .asciiLayout && !$0.isBuiltInVietnamese }
        var seen = Set<InputSourceID>()
        rows = layouts.compactMap { source in
            guard seen.insert(source.id).inserted else { return nil }
            let assignment: Assignment =
                binding.vietnamese.contains(source.id)
                ? .vietnamese : binding.english.contains(source.id) ? .english : .none
            return Row(id: source.id, name: source.localizedName, assignment: assignment)
        }
    }

    /// The binding decides the mode only with at least one layout per mode; the pane says so otherwise.
    public var isComplete: Bool { !binding.vietnamese.isEmpty && !binding.english.isEmpty }

    public func settingEnabled(_ enabled: Bool) -> LayoutModeBinding {
        var next = binding
        next.enabled = enabled
        return next
    }

    /// A layout is in at most one list.
    public func assigning(_ assignment: Assignment, to id: InputSourceID) -> LayoutModeBinding {
        var next = binding
        next.vietnamese.removeAll { $0 == id }
        next.english.removeAll { $0 == id }
        switch assignment {
        case .none: break
        case .vietnamese: next.vietnamese.append(id)
        case .english: next.english.append(id)
        }
        return next
    }
}
