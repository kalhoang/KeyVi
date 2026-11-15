// SPDX-License-Identifier: MPL-2.0

/// Up to four phrase-word numbers packed into one integer, 16 bits each, oldest word in the low bits
/// (ENG-R826). Numbers start at 1, so phrases of different lengths never share a key, and a lookup costs
/// one hash of a `UInt64`: no string or array is built at commit (ENG-R1232, PLT-R304).
package struct PhraseWords: Sendable, Hashable {
    package private(set) var key: UInt64 = 0
    package private(set) var count = 0

    package init() {}

    /// Appends the number of the next word; a fifth word is ignored (no phrase is longer than four).
    package mutating func append(_ number: UInt16) {
        guard count < PhraseList.maximumWords else { return }
        key |= UInt64(number) << UInt64(16 * count)
        count += 1
    }
}

/// The phrase-word numbers of the committed tokens just before a commit (ENG-R826): the longest chain of
/// tokens of the run that ends at the newest history entries, each token followed by exactly one space and
/// each a word of some phrase. At most three are kept, the most rule L9b looks back; RV1 reads the same
/// chain, whose nearest token is then the token it may revise.
package struct PhraseChain: Sendable, Hashable {
    private var nearest: UInt16 = 0
    private var second: UInt16 = 0
    private var third: UInt16 = 0
    /// Tokens in the chain, 0 to 3.
    package private(set) var count = 0

    package init() {}

    /// The chain for a token that commits right after the newest entries of `history`; empty unless the
    /// newest entry is a single space after a token.
    package init(history: History) {
        var expectsSpace = true
        for entry in history.entries.reversed() {
            guard count < 3 else { return }
            switch entry {
            case .boundary(let character):
                guard expectsSpace, character == " " else { return }
                expectsSpace = false
            case .token(let committed):
                let number = committed.collision.phraseWord
                guard !expectsSpace, number != 0 else { return }
                push(number)
                expectsSpace = true
            }
        }
    }

    private mutating func push(_ number: UInt16) {
        switch count {
        case 0: nearest = number
        case 1: second = number
        default: third = number
        }
        count += 1
    }

    /// The number of the token at `distance` (1 is the nearest).
    private func number(at distance: Int) -> UInt16 {
        switch distance {
        case 1: nearest
        case 2: second
        default: third
        }
    }

    /// The last `older` tokens of the chain, oldest first, then `newer`. Nil when the chain is shorter than
    /// `older` or `newer` is 0 (a word in no phrase).
    package func words(last older: Int, then newer: UInt16) -> PhraseWords? {
        guard older <= count, newer != 0 else { return nil }
        var words = PhraseWords()
        var distance = older
        while distance >= 1 {
            words.append(number(at: distance))
            distance -= 1
        }
        words.append(newer)
        return words
    }
}
