// SPDX-License-Identifier: MPL-2.0

/// A token after its commit, kept so that Backspace can re-open it (ENG-R1001).
package struct CommittedToken: Sendable, Hashable {
    /// The token as it was at commit: raw keys, composition (escape-used, camel case) and flags.
    package var token: ActiveToken
    /// The text the commit left on screen for the token.
    package var committedText: String
    /// The reason code of the commit (ENG-R801); nil until section 8 (E3) decides commits.
    package var decision: CommitDecision?

    package init(token: ActiveToken, committedText: String, decision: CommitDecision?) {
        self.token = token
        self.committedText = committedText
        self.decision = decision
    }
}

/// One entry of the run (spec 0 "Run", 10.1): a committed token or a boundary character typed after it.
package enum HistoryEntry: Sendable, Hashable {
    case token(CommittedToken)
    case boundary(Character)
}

/// The committed tokens of the current run and the boundary characters between them, oldest first
/// (ENG-R1001, ENG-R910).
///
/// E2 records entries and enforces the limits; section 10 (E3) adds re-opening by Backspace
/// (ENG-R1002, ENG-R1003) and section 11 reads the macro span from the boundary entries (ENG-R1102).
package struct History: Sendable, Hashable {
    /// Upper bound on entries per allowed token, so that runs of boundary characters (thousands of
    /// spaces) cannot grow the history without bound (ENG-T30). Only the oldest entries are dropped.
    package static let entriesPerToken = 64

    package private(set) var entries: [HistoryEntry] = []
    package private(set) var tokenCount = 0

    package init() {}

    /// ENG-R1001: keeps at most `limit` tokens (`EngineConfiguration.historyLimit`, minimum 1); older
    /// entries are dropped, never a crash.
    package mutating func record(_ token: CommittedToken, limit: Int) {
        entries.append(.token(token))
        tokenCount += 1
        trim(limit: limit)
    }

    /// ENG-R910: boundary characters are recorded so Backspace can walk back over them.
    package mutating func record(boundary: Character, limit: Int) {
        entries.append(.boundary(boundary))
        trim(limit: limit)
    }

    /// ENG-R912 (Return, Tab) and ENG-R1011 (reset).
    package mutating func clear() {
        entries.removeAll()
        tokenCount = 0
    }

    private mutating func trim(limit: Int) {
        let tokenLimit = max(1, limit)
        let entryLimit = tokenLimit * Self.entriesPerToken
        var dropCount = 0
        var droppedTokens = 0
        while tokenCount - droppedTokens > tokenLimit || entries.count - dropCount > entryLimit {
            if case .token = entries[dropCount] { droppedTokens += 1 }
            dropCount += 1
        }
        guard dropCount > 0 else { return }
        entries.removeFirst(dropCount)
        tokenCount -= droppedTokens
    }
}
