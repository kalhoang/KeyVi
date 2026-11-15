// SPDX-License-Identifier: MPL-2.0

/// The weak signals of the three newest committed tokens of the run, oldest first (ENG-R864). A token's
/// decision becomes final untouched after three later commits or at Return or Tab; until then a revision,
/// its undo, a Backspace that re-opens the token, a macro that folds it or a reset withdraws the signal.
/// Mirrors the newest tokens of the history in fixed storage, so committing costs O(1) whatever the
/// history holds (ENG-R1232) and allocates nothing (PLT-R304).
package struct PendingSignals: Sendable, Hashable {
    private var oldest: CollisionSignal?
    private var middle: CollisionSignal?
    private var newest: CollisionSignal?
    /// Tokens tracked, 0 to 3.
    package private(set) var count = 0

    package init() {}

    /// Records the newest committed token's signal (nil when it has none) and returns the signal of the
    /// token that now has three later commits.
    package mutating func push(_ signal: CollisionSignal?) -> CollisionSignal? {
        var due: CollisionSignal?
        switch count {
        case 0: oldest = signal
        case 1: middle = signal
        case 2: newest = signal
        default:
            due = oldest
            oldest = middle
            middle = newest
            newest = signal
        }
        count = min(count + 1, 3)
        return due
    }

    /// The newest token left the history (Backspace re-opened it, a macro folded it).
    package mutating func popNewest() {
        switch count {
        case 0: return
        case 1: oldest = nil
        case 2: middle = nil
        default: newest = nil
        }
        count -= 1
    }

    /// Withdraws the signal of the token at `distance` (1 is the newest): a revised token never counts.
    package mutating func withdraw(atDistance distance: Int) {
        let index = count - distance
        switch index {
        case 0: oldest = nil
        case 1: middle = nil
        case 2: newest = nil
        default: return
        }
    }

    /// Every pending signal, oldest first, and an empty queue (Return or Tab ends the run's history).
    package mutating func flush() -> [CollisionSignal] {
        var signals: [CollisionSignal] = []
        if count > 0, let oldest { signals.append(oldest) }
        if count > 1, let middle { signals.append(middle) }
        if count > 2, let newest { signals.append(newest) }
        self = PendingSignals()
        return signals
    }
}

extension Engine {
    /// The class of the previous token for the memory (ENG-R863): sentence start when the run has no token
    /// yet or when `.`, `!`, `?` or `:` follows the newest token; otherwise the newest token's language.
    /// The walk stops after one token's worth of boundary characters (`History.entriesPerToken`).
    static func memoryContext(_ history: History) -> CollisionContext {
        var afterSentenceMark = false
        var offset = 0
        while offset < History.entriesPerToken, let entry = history.entry(beforeNewest: offset) {
            switch entry {
            case .boundary(let character):
                switch character.asciiValue {
                case 0x2E, 0x21, 0x3F, 0x3A: afterSentenceMark = true
                default: break
                }
            case .token(let committed):
                if afterSentenceMark { return .sentenceStart }
                switch committed.language {
                case .vietnamese: return .afterVietnamese
                case .english: return .afterEnglish
                case .neutral: return .afterNeutral
                }
            }
            offset += 1
        }
        return .sentenceStart
    }
}
