// SPDX-License-Identifier: MPL-2.0

/// What the collision rules (ENG-R825 to ENG-R829) and the learning signals (ENG-R864) need to know about a
/// committed token.
package struct CollisionFacts: Sendable, Hashable {
    /// `R` lowercased (ASCII only, ENG-R905); empty for a macro expansion.
    package var rawLowercased = ""
    /// `C`, the composed form the rules would keep (the Vietnamese display); empty for a macro expansion.
    package var composed = ""
    /// The number of the raw keys in the phrase list (0: the word is in no phrase, ENG-R826).
    package var phraseWord: UInt16 = 0
    /// The class of the previous token when this token committed (ENG-R863).
    package var context = CollisionContext.sentenceStart
    /// The bundled collision-list word equal to the raw keys (ENG-R866); nil when the word is not on the list.
    package var listWord: String?
    /// The revision that changed the token (ENG-R828); a revised token is never revised again.
    package var revision: RevisionReason?

    package init() {}
}

/// A token after its commit, kept so that Backspace can re-open it (ENG-R1001).
package struct CommittedToken: Sendable, Hashable {
    /// The token as it was at commit: raw keys, composition (escape-used, camel case) and flags. For a
    /// macro expansion (ENG-R1104) a literal token whose raw keys are the span as typed.
    package var token: ActiveToken
    /// The text the commit left on screen for the token.
    package var committedText: String
    /// The reason code of the commit (ENG-R801) or `.macro` (ENG-R1104).
    package var decision: CommitDecision
    /// ENG-R823: the language of the token.
    package var language: TokenLanguage
    /// The run's language window before this token was committed; restored when the token is re-opened
    /// or folded into a macro expansion.
    package var languagesBefore: RecentLanguages
    /// The collision facts of the token (ENG-R825 to ENG-R829, ENG-R864).
    package var collision: CollisionFacts

    package init(
        token: ActiveToken, committedText: String, decision: CommitDecision, language: TokenLanguage,
        languagesBefore: RecentLanguages, collision: CollisionFacts = CollisionFacts()
    ) {
        self.token = token
        self.committedText = committedText
        self.decision = decision
        self.language = language
        self.languagesBefore = languagesBefore
        self.collision = collision
    }

    /// The token shows its raw keys because of a rule: its decision restored it (not the user's toggle), or a
    /// revision restored it (ENG-R828).
    package var showsRawKeysByRule: Bool {
        if let revision = collision.revision { return revision.restores }
        if case .restored(let rule) = decision, rule != .userChoice { return true }
        return false
    }

    /// The token shows its raw keys, whoever decided it.
    package var showsRawKeys: Bool {
        if let revision = collision.revision { return revision.restores }
        return decision.restores
    }

    /// ENG-R1002: the token re-opened as the active token "with all its raw keys and flags". Its display
    /// is what the commit left on screen. A token that a commit rule or a revision restored shows its raw
    /// keys and the toggle can bring the composed form back (ENG-R701, ENG-R704); the user's own choice
    /// (L1) is kept in `userChoice`. A revised token remembers the revision's side (ENG-R864).
    package var reopened: ActiveToken {
        token.reopened(
            display: committedText, restoredByRule: showsRawKeysByRule, revisionRestored: collision.revision?.restores)
    }
}

/// One entry of the run (spec 0 "Run", 10.1): a committed token or a boundary character typed after it.
package enum HistoryEntry: Sendable, Hashable {
    case token(CommittedToken)
    case boundary(Character)

    /// The text the entry occupies on screen.
    package var text: String {
        switch self {
        case .token(let token): return token.committedText
        case .boundary(let character): return String(character)
        }
    }
}

/// The committed tokens of the current run and the boundary characters between them, oldest first
/// (ENG-R1001, ENG-R910).
///
/// Storage is an array with a head offset: dropping the oldest entries only moves the head, and the
/// array is compacted when more than half of it is dropped, so trimming is amortised O(1) (ENG-R1232).
package struct History: Sendable {
    /// Upper bound on entries per allowed token, so that runs of boundary characters (thousands of
    /// spaces) cannot grow the history without bound (ENG-T30). Only the oldest entries are dropped.
    package static let entriesPerToken = 64

    /// The entry bound for `tokenLimit` tokens (`tokenLimit x entriesPerToken`, at least one token). It
    /// saturates at `Int.max`: a host may pass a huge `historyLimit` to mean "unlimited", and ENG-R1001
    /// and ENG-T30 forbid a trap on the first commit.
    package static func entryLimit(forTokens tokenLimit: Int) -> Int {
        let (product, overflow) = max(1, tokenLimit).multipliedReportingOverflow(by: entriesPerToken)
        return overflow ? .max : product
    }

    private var storage: [HistoryEntry] = []
    private var head = 0
    package private(set) var tokenCount = 0
    /// Trimming dropped entries in the middle of a macro span (ENG-R1102): the characters typed before
    /// the first kept entry are unknown, so a span that reaches the start cannot be matched.
    package private(set) var startsMidSpan = false

    package init() {}

    /// The entries, oldest first.
    package var entries: ArraySlice<HistoryEntry> { storage[head...] }

    package var isEmpty: Bool { head == storage.count }

    package var last: HistoryEntry? { isEmpty ? nil : storage[storage.count - 1] }

    /// ENG-R1001: keeps at most `limit` tokens (`EngineConfiguration.historyLimit`, minimum 1); older
    /// entries are dropped, never a crash.
    package mutating func record(_ token: CommittedToken, limit: Int) {
        storage.append(.token(token))
        tokenCount += 1
        trim(limit: limit)
    }

    /// ENG-R910: boundary characters are recorded so Backspace can walk back over them and macro spans
    /// can include them.
    package mutating func record(boundary: Character, limit: Int) {
        storage.append(.boundary(boundary))
        trim(limit: limit)
    }

    /// The entry `offset` entries before the newest one (0 is the newest), nil past the oldest.
    package func entry(beforeNewest offset: Int) -> HistoryEntry? {
        let index = storage.count - 1 - offset
        return index >= head && index < storage.count ? storage[index] : nil
    }

    /// The token `offset` entries before the newest entry, nil when that entry is a boundary or missing.
    package func token(beforeNewest offset: Int) -> CommittedToken? {
        guard case .token(let token)? = entry(beforeNewest: offset) else { return nil }
        return token
    }

    /// Applies `update` to the token `offset` entries before the newest entry; nothing happens when that
    /// entry is not a token (revision and its undo, ENG-R828, ENG-R829; weak signals, ENG-R864).
    package mutating func updateToken(beforeNewest offset: Int, _ update: (inout CommittedToken) -> Void) {
        let index = storage.count - 1 - offset
        guard index >= head, index < storage.count, case .token(var token) = storage[index] else { return }
        update(&token)
        storage[index] = .token(token)
    }

    /// Removes the newest entry (Backspace re-opening, ENG-R1002; macro expansion, ENG-R1103).
    @discardableResult
    package mutating func popLast() -> HistoryEntry? {
        guard !isEmpty else { return nil }
        let entry = storage.removeLast()
        if case .token = entry { tokenCount -= 1 }
        if isEmpty {
            storage.removeAll(keepingCapacity: true)
            head = 0
        }
        return entry
    }

    /// ENG-R912 (Return, Tab) and ENG-R1011 (reset). The span starts afresh.
    package mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        tokenCount = 0
        startsMidSpan = false
    }

    private mutating func trim(limit: Int) {
        let tokenLimit = max(1, limit)
        let entryLimit = Self.entryLimit(forTokens: tokenLimit)
        var droppedLast: HistoryEntry?
        while tokenCount > tokenLimit || storage.count - head > entryLimit {
            let entry = storage[head]
            if case .token = entry { tokenCount -= 1 }
            droppedLast = entry
            head += 1
        }
        guard let droppedLast else { return }
        // The span start is known only if the last dropped entry was whitespace (ENG-R1102).
        if case .boundary(let character) = droppedLast, character.isWhitespace {
            startsMidSpan = false
        } else {
            startsMidSpan = true
        }
        if head > 32, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

extension History: Hashable {
    /// Two histories are equal when they hold the same entries, whatever the head offset.
    package static func == (lhs: History, rhs: History) -> Bool {
        lhs.tokenCount == rhs.tokenCount && lhs.startsMidSpan == rhs.startsMidSpan && lhs.entries == rhs.entries
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(tokenCount)
        hasher.combine(startsMidSpan)
        hasher.combine(entries.count)
        for entry in entries { hasher.combine(entry) }
    }
}
