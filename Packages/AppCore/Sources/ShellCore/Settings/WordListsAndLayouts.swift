// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two English-restore user lists of the Typing pane (ENG-R860) and the optional layout-to-mode binding of
// General > Advanced (PLT-R373).

public import AppModel
internal import Foundation
public import InputHost
public import SettingsStore

/// ENG-R860: "keep as typed" and "keep Vietnamese", keyed by lowercased raw keys. Entries are user-authored text,
/// allowed on disk (PLT-R901 a) and never logged.
public enum UserWordList: String, Sendable, Hashable, CaseIterable {
    case keepAsTyped, keepVietnamese

    public static let maxEntryLength = 32

    public enum AddResult: Sendable, Hashable {
        case added(Set<String>)
        case invalid
        case duplicate
    }

    public func entries(in settings: EffectiveSettings) -> [String] {
        let set = self == .keepAsTyped ? settings.keepAsTyped : settings.keepVietnamese
        return set.sorted()
    }

    public func edit(_ entries: Set<String>) -> SettingsEdit {
        self == .keepAsTyped ? .keepAsTyped(entries) : .keepVietnamese(entries)
    }

    /// Raw keys are printable ASCII without whitespace (the keys of the user's layout as typed), lowercased.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= maxEntryLength,
            trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        return trimmed
    }

    public static func adding(_ text: String, to current: Set<String>) -> AddResult {
        guard let entry = normalized(text) else { return .invalid }
        guard !current.contains(entry) else { return .duplicate }
        return .added(current.union([entry]))
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
