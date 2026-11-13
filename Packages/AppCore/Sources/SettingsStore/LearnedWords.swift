// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-app learning of the English-restore user lists (ENG-R860, ENG-R861, ENG-R862; decision of the product owner,
// 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md Q16, docs/decisions/0320-per-app-learned-words.md).
// A word learned from the user's toggles applies only in the app where it was learned; a word typed in Settings
// is global. The engine never sees an app (ENG-R851): for the focused app the host passes `wordLists(for:)`.
// Entries are user-authored content: on disk and in Settings only, never logged (PLT-R901 a).

public import AppModel

/// The two English-restore user lists (ENG-R860), named as in `settings.json` (`englishRestoreLists`).
public enum RestoreList: String, Sendable, Hashable, CaseIterable, Comparable {
    case keepAsTyped, keepVietnamese

    /// The other list: a word belongs to at most one of them for a given app.
    public var opposite: RestoreList { self == .keepAsTyped ? .keepVietnamese : .keepAsTyped }

    public static func < (lhs: RestoreList, rhs: RestoreList) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A word learned from the user's toggles in one app (ENG-R862). It applies only in `app`.
public struct LearnedWord: Sendable, Hashable, Comparable {
    public var list: RestoreList
    /// Lowercased raw keys (ENG-R860).
    public var raw: String
    /// The app it was learned in. Settings resolves its display name when it shows the entry; the name is never
    /// stored.
    public var app: BundleKey

    public init(list: RestoreList, raw: String, app: BundleKey) {
        self.list = list
        self.raw = raw.lowercased()
        self.app = app
    }

    /// By word, then list, then app: the order of the Settings rows and of the file.
    public static func < (lhs: LearnedWord, rhs: LearnedWord) -> Bool {
        (lhs.raw, lhs.list, lhs.app) < (rhs.raw, rhs.list, rhs.app)
    }
}

/// The user lists the engine gets for one app (`Resources.userKeepRaw`, `Resources.userKeepVietnamese`).
public struct UserWordLists: Sendable, Hashable {
    public var keepAsTyped: Set<String>
    public var keepVietnamese: Set<String>

    public init(keepAsTyped: Set<String> = [], keepVietnamese: Set<String> = []) {
        self.keepAsTyped = keepAsTyped
        self.keepVietnamese = keepVietnamese
    }

    public subscript(list: RestoreList) -> Set<String> {
        list == .keepAsTyped ? keepAsTyped : keepVietnamese
    }
}

extension UserSettings {
    /// Global entries of `list`: typed in Settings, made global, or saved before per-app learning existed.
    public func globalWords(in list: RestoreList) -> Set<String> {
        list == .keepAsTyped ? keepAsTyped : keepVietnamese
    }

    /// The global entries only, for a field whose app is unknown.
    public var globalWordLists: UserWordLists {
        UserWordLists(keepAsTyped: keepAsTyped, keepVietnamese: keepVietnamese)
    }

    /// ENG-R851, ENG-R862: the global entries plus the entries learned in `app`. A word learned in `app` wins over a
    /// global entry of the other list for the same word, because it is the user's more specific choice.
    public func wordLists(for app: BundleKey?) -> UserWordLists {
        guard let app else { return globalWordLists }
        var learnedRaw = Set<String>()
        var learnedVietnamese = Set<String>()
        for word in learnedWords where word.app == app {
            if word.list == .keepAsTyped { learnedRaw.insert(word.raw) } else { learnedVietnamese.insert(word.raw) }
        }
        return UserWordLists(
            keepAsTyped: keepAsTyped.subtracting(learnedVietnamese).union(learnedRaw),
            keepVietnamese: keepVietnamese.subtracting(learnedRaw).union(learnedVietnamese))
    }

    /// ENG-R862: the host saw the same learning signal twice in `app`. The newest choice wins in that app: the
    /// word leaves the other list's learned entries of `app` (ENG-R860). Nothing is added when a global entry
    /// already gives `app` this behaviour.
    public mutating func learn(_ raw: String, in list: RestoreList, app: BundleKey) {
        let word = LearnedWord(list: list, raw: raw, app: app)
        guard !word.raw.isEmpty else { return }
        learnedWords.remove(LearnedWord(list: list.opposite, raw: word.raw, app: app))
        if globalWords(in: list).contains(word.raw) && !globalWords(in: list.opposite).contains(word.raw) { return }
        learnedWords.insert(word)
    }

    /// Settings "remove" on a learned entry.
    public mutating func forget(_ word: LearnedWord) {
        learnedWords.remove(word)
    }

    /// Settings "use in every app": the word becomes a global entry of its list and leaves the other global list
    /// (newest choice wins, ENG-R860). Copies learned for the same list in other apps are dropped, the global
    /// entry covers them; words learned for the other list in other apps keep overriding it there.
    public mutating func makeGlobal(_ word: LearnedWord) {
        guard learnedWords.contains(word) else { return }
        learnedWords = learnedWords.filter { $0.list != word.list || $0.raw != word.raw }
        setGlobal(globalWords(in: word.list).union([word.raw]), in: word.list)
        setGlobal(globalWords(in: word.list.opposite).subtracting([word.raw]), in: word.list.opposite)
    }

    /// Replaces the global entries of `list` (the Settings list editor). Learned entries of the same list for a word
    /// that is now global are dropped as redundant.
    public mutating func setGlobalWords(_ words: Set<String>, in list: RestoreList) {
        setGlobal(words, in: list)
        learnedWords = learnedWords.filter { $0.list != list || !words.contains($0.raw) }
    }

    private mutating func setGlobal(_ words: Set<String>, in list: RestoreList) {
        if list == .keepAsTyped { keepAsTyped = words } else { keepVietnamese = words }
    }
}

/// `englishRestoreLists.learnedWords` of settings.json: `[{ "list": "keepAsTyped", "raw": "cos", "app": "<bundle>" }]`
/// (ADR 0320). Added without a schema change: older builds keep the key unread (PLT-R1002).
enum LearnedWordsCodec {
    static let key = "learnedWords"

    /// One item of the array. An item without `app` (or with `null`) is a global entry of its list (ENG-R862: an
    /// entry learned before per-app learning, or written by hand, applies everywhere). Nil for an unreadable item.
    enum Item: Equatable {
        case learned(LearnedWord)
        case global(RestoreList, String)
    }

    static func item(from value: JSONValue) -> Item? {
        guard let object = value.objectValue,
            let list = object["list"]?.stringValue.flatMap(RestoreList.init(rawValue:)),
            let raw = object["raw"]?.stringValue?.lowercased(), !raw.isEmpty
        else { return nil }
        switch object["app"] {
        case nil, .null?: return .global(list, raw)
        case .string(let app)?:
            return BundleKey(rawValue: app).map { .learned(LearnedWord(list: list, raw: raw, app: $0)) }
        default: return nil
        }
    }

    /// Sorted entries, each over the raw item it was read from, so unknown keys inside an item survive (PLT-R1002).
    static func encode(_ words: Set<LearnedWord>, over rawItems: [JSONValue]) -> JSONValue {
        var rawByWord: [LearnedWord: [String: JSONValue]] = [:]
        for value in rawItems {
            if case .learned(let word)? = item(from: value), rawByWord[word] == nil, let object = value.objectValue {
                rawByWord[word] = object
            }
        }
        return .array(
            words.sorted().map { word in
                var object = rawByWord[word] ?? [:]
                object["list"] = .string(word.list.rawValue)
                object["raw"] = .string(word.raw)
                object["app"] = .string(word.app.rawValue)
                return .object(object)
            })
    }

    /// Indexes of unreadable items (import summary, PLT-R1010).
    static func unreadableIndexes(in value: JSONValue?) -> [Int] {
        arrayItems(value).enumerated().filter { item(from: $0.element) == nil }.map(\.offset)
    }
}
