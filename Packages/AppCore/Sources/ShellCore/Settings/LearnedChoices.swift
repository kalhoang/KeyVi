// SPDX-License-Identifier: GPL-3.0-or-later
//
// The learned-words sheet of the Typing pane (PRD-R78; decision of the product owner, 15/11/2026: which reading of a
// word that is both English and Vietnamese the user chooses is learned per user across all apps). One row per entry
// of the collision memory that votes for a side now, rendered from the bundled word itself: its keys, an arrow, what
// it becomes (the keys for English, the engine's Telex reading for Vietnamese) and the context class in words. A row
// never shows counters, apps or neighbouring words; entries in conflict or with acceptances only are not choices and
// are not listed, though "Xóa tất cả" deletes them too (PLT-R914). The words are bundled vocabulary and are never
// logged (PLT-R901).

public import AppModel
public import SettingsStore
internal import VietnameseEngine

/// One row of the sheet.
public struct LearnedChoiceRow: Sendable, Hashable, Identifiable {
    /// The entry: a bundled collision word (lowercased raw keys) and its context class, nil for any context.
    public let key: CollisionMemoryKey
    /// The side the entry votes for.
    public let side: CollisionMemorySide
    /// What the word becomes: the keys themselves for English, the Vietnamese reading for Vietnamese.
    public let result: String

    public var id: CollisionMemoryKey { key }
    public var word: String { key.word }
    public var context: CollisionMemoryContext? { key.context }

    /// "Remove" for this row only; the store forgets this entry and keeps the word's other entries.
    public var forgetEdit: SettingsEdit { .forgetLearnedChoice(key) }

    /// The context class in words (ENG-R863).
    public func contextText(_ localizer: Localizer) -> String {
        localizer.string(LearnedChoices.contextText(key.context))
    }

    /// VoiceOver reads the row as one sentence (PRD-R66): "as thành á, sau từ tiếng Việt".
    public func accessibilityText(_ localizer: Localizer) -> String {
        switch side {
        case .vietnamese: localizer.format(SettingsText.learnedRowVietnamese, word, result, contextText(localizer))
        case .english: localizer.format(SettingsText.learnedRowEnglish, word, contextText(localizer))
        }
    }

    /// Help and VoiceOver label of the row's remove button: two rows of one word differ by their context.
    public func removeLabel(_ localizer: Localizer) -> String {
        localizer.format(SettingsText.listRemove, word) + ", " + contextText(localizer)
    }
}

/// What the sheet shows: the rows in the memory's key order (word, then the any-context entry, then sentence start,
/// after a Vietnamese, English and neutral word), whether the "Xóa tất cả" confirmation is open, and whether the memory
/// could be loaded at all (PLT-R914: when the bundled lists failed to load, nothing is recorded, written, removed or
/// cleared, so the sheet has no rows, offers no edit and says so in one line).
public struct LearnedChoicesSheetState: Sendable, Hashable {
    public let rows: [LearnedChoiceRow]
    public let confirmsClearAll: Bool
    /// The memory is not loaded (`SettingsCommands.learnedChoices()` returned nil).
    public let isUnavailable: Bool

    /// `votes` nil: the memory is not loaded. `reading` gives a word's Vietnamese reading; the default types the
    /// bundled word with the engine (Telex with the default options and the traditional placement, no restore), so
    /// nothing the user typed is stored or shown. The window passes `LearnedChoiceReading.vietnamese(for:)` with the
    /// user's settings.
    public init(
        votes: [CollisionMemoryVote]?,
        reading: (String) -> String = LearnedChoiceReading.vietnamese(tonePlacement: .traditional)
    ) {
        self.init(
            rows: votes.map { LearnedChoices.rows($0, reading: reading) } ?? [], confirmsClearAll: false,
            isUnavailable: votes == nil)
    }

    private init(rows: [LearnedChoiceRow], confirmsClearAll: Bool, isUnavailable: Bool) {
        self.rows = rows
        self.confirmsClearAll = confirmsClearAll && !isUnavailable
        self.isUnavailable = isUnavailable
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// Remove and "Xóa tất cả..." are enabled: the memory is loaded, even when no row is listed (clearing also
    /// removes entries the sheet does not list).
    public var canEdit: Bool { !isUnavailable }

    /// The sheet once `row` is removed.
    public func removing(_ row: LearnedChoiceRow) -> LearnedChoicesSheetState {
        LearnedChoicesSheetState(
            rows: rows.filter { $0.id != row.id }, confirmsClearAll: confirmsClearAll, isUnavailable: isUnavailable)
    }

    /// The sheet after "Xóa tất cả": empty, the confirmation closed.
    public var cleared: LearnedChoicesSheetState {
        LearnedChoicesSheetState(rows: [], confirmsClearAll: false, isUnavailable: isUnavailable)
    }

    /// Opens or closes the "Xóa tất cả" confirmation; it never opens while the memory is not loaded.
    public func confirmingClearAll(_ confirms: Bool) -> LearnedChoicesSheetState {
        LearnedChoicesSheetState(rows: rows, confirmsClearAll: confirms, isUnavailable: isUnavailable)
    }

    /// New votes from the store (after an edit; nil: the memory is not loaded); an open confirmation stays open.
    public func replacingVotes(
        _ votes: [CollisionMemoryVote]?,
        reading: (String) -> String = LearnedChoiceReading.vietnamese(tonePlacement: .traditional)
    ) -> LearnedChoicesSheetState {
        LearnedChoicesSheetState(
            rows: votes.map { LearnedChoices.rows($0, reading: reading) } ?? [], confirmsClearAll: confirmsClearAll,
            isUnavailable: votes == nil)
    }

    /// The one line shown instead of the list while the memory is not loaded (PRD-R78, PRD-R79): the list could not
    /// be loaded and reopening the app may help.
    public static func unavailableText(appName: String, _ localizer: Localizer) -> String {
        localizer.format(SettingsText.learnedChoicesUnavailable, appName)
    }

    /// The empty state (PRD-R79): how words are learned, with the restore key the user has now (D8). Strong signals
    /// come from the restore toggle (ENG-R864): Escape, D8's default, keeps the draft's wording; another key is
    /// named in words; with D8 off the text says the key is off.
    public static func emptyText(appName: String, settings: EffectiveSettings, _ localizer: Localizer) -> String {
        emptyText(appName: appName, restoreHotkey: settings.restoreHotkey, localizer)
    }

    public static func emptyText(appName: String, restoreHotkey: HotkeyBinding?, _ localizer: Localizer) -> String {
        switch restoreHotkey {
        case nil: localizer.format(SettingsText.learnedChoicesEmptyNoKey, appName)
        case .key(.escape)?: localizer.format(SettingsText.learnedChoicesEmpty, appName)
        case let binding?:
            localizer.format(
                SettingsText.learnedChoicesEmptyOtherKey, appName,
                ShortcutWords.string(for: binding, localizer: localizer))
        }
    }
}

/// The Vietnamese reading of a bundled collision word for the sheet, with the user's settings (D2 tone placement, D5
/// lone w): the engine types the word key by key with Telex and no restore (`toes` gives tóe, or toé with the modern
/// placement), so the row shows the word as the user would see it and nothing the user typed is stored or shown
/// (PLT-R901). A word with digits that Telex leaves as it is (the VNI rows `a4`, `o2`) gets its VNI reading.
public enum LearnedChoiceReading {
    /// The reading for the settings the window has now.
    public static func vietnamese(for settings: EffectiveSettings) -> @Sendable (String) -> String {
        vietnamese(tonePlacement: settings.tonePlacement, standaloneW: settings.telexStandaloneW)
    }

    /// The reading for `tonePlacement` and D5; the word itself when it does not compose.
    public static func vietnamese(tonePlacement: TonePlacement, standaloneW: Bool = true)
        -> @Sendable (String) -> String
    {
        let style: ToneStyle = tonePlacement == .modern ? .modern : .traditional
        let telex = engine(.telex(TelexOptions(standaloneW: standaloneW)), style)
        let vni = engine(.vni, style)
        return { word in
            let display = reading(word, telex)
            guard display == word, word.contains(where: \.isNumber) else { return display }
            return reading(word, vni)
        }
    }

    private static func reading(_ word: String, _ engine: Engine) -> String {
        var session = Session(engine: engine)
        for character in word { _ = session.handle(.key(KeyInput(character))) }
        let display = session.state.activeDisplay
        return display.isEmpty ? word : display
    }

    private static func engine(_ method: InputMethod, _ style: ToneStyle) -> Engine {
        Engine(
            configuration: EngineConfiguration(inputMethod: method, toneStyle: style, autoRestore: false),
            resources: .empty)
    }
}

enum LearnedChoices {
    /// Rows for the entries that vote for a side, in key order; conflicts are left to the rules and not listed.
    static func rows(_ votes: [CollisionMemoryVote], reading: (String) -> String) -> [LearnedChoiceRow] {
        votes.compactMap { vote -> LearnedChoiceRow? in
            let key = CollisionMemoryKey(word: vote.word, context: vote.context)
            switch vote.choice {
            case .english: return LearnedChoiceRow(key: key, side: .english, result: vote.word)
            case .vietnamese: return LearnedChoiceRow(key: key, side: .vietnamese, result: reading(vote.word))
            case .conflict: return nil
            }
        }
        .sorted { $0.key < $1.key }
    }

    static func contextText(_ context: CollisionMemoryContext?) -> SettingsText {
        switch context {
        case .sentenceStart?: .learnedContextSentenceStart
        case .afterVietnamese?: .learnedContextAfterVietnamese
        case .afterEnglish?: .learnedContextAfterEnglish
        case .afterNeutral?: .learnedContextAfterNeutral
        case nil: .learnedContextAny
        }
    }
}
