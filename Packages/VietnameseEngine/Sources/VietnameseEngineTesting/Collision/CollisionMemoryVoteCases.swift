// SPDX-License-Identifier: MPL-2.0
//
// Worked cases of the learned-memory vote (spec/01-engine.md ENG-R863), each a sequence of collision signals and
// the votes and lookups the text of ENG-R863 gives for it, computed by hand from the text. `ReferenceCollisionMemory`
// passes them (CollisionCorpusTests), and the host's memory store runs the same table so that both read the
// requirement the same way (parity test of workstream W11-B).

public import VietnameseEngine

/// The worked cases of ENG-R863.
public enum CollisionMemoryVoteCases {
    /// One case: signals in order, then the expected vote of each listed entry and the expected lookups.
    public struct Case: Sendable, CustomStringConvertible {
        /// What the case shows.
        public let name: String
        /// The signals, in order.
        public let signals: [CollisionSignal]
        /// Entry votes: word, context (nil for the any-context entry), expected vote (nil: no vote).
        public let votes: [(word: String, context: CollisionContext?, vote: CollisionVote?)]
        /// Lookups at commit (`CollisionMemorySnapshot.vote(word:context:)`): nil means the rules decide.
        public let lookups: [(word: String, context: CollisionContext, decision: Language?)]

        /// The name.
        public var description: String { name }
    }

    private static func strong(_ side: Language, _ context: CollisionContext, word: String = "as") -> CollisionSignal {
        CollisionSignal(word: word, context: context, side: side, strength: .strong)
    }

    private static func weak(_ side: Language, _ context: CollisionContext, word: String = "as") -> CollisionSignal {
        CollisionSignal(word: word, context: context, side: side, strength: .weak)
    }

    private static func repeated(_ signal: CollisionSignal, _ count: Int) -> [CollisionSignal] {
        Array(repeating: signal, count: count)
    }

    /// Every case.
    public static let all: [Case] = thresholds + conflicts + anyContext

    /// The score threshold, the own-acceptance cap and silent acceptance alone.
    static let thresholds: [Case] = [
        Case(
            name: "one correction scores 1: no vote", signals: [strong(.english, .afterEnglish)],
            votes: [("as", .afterEnglish, nil), ("as", nil, nil)], lookups: [("as", .afterEnglish, nil)]),
        Case(
            name: "two corrections in one class: the class entry votes, the any-context entry needs two classes",
            signals: repeated(strong(.english, .afterEnglish), 2),
            votes: [("as", .afterEnglish, .english), ("as", nil, nil)],
            lookups: [("as", .afterEnglish, .english), ("as", .afterVietnamese, nil)]),
        Case(
            name: "one correction and four acceptances of the same side score 2",
            signals: [strong(.english, .afterNeutral)] + repeated(weak(.english, .afterNeutral), 4),
            votes: [("as", .afterNeutral, .english)], lookups: [("as", .afterNeutral, .english)]),
        Case(
            name: "one correction and three acceptances score 1.75: no vote",
            signals: [strong(.english, .afterNeutral)] + repeated(weak(.english, .afterNeutral), 3),
            votes: [("as", .afterNeutral, nil)], lookups: [("as", .afterNeutral, nil)]),
        Case(
            name: "own acceptances count up to four",
            signals: [strong(.vietnamese, .sentenceStart)] + repeated(weak(.vietnamese, .sentenceStart), 64),
            votes: [("as", .sentenceStart, .vietnamese)], lookups: [("as", .sentenceStart, .vietnamese)]),
        Case(
            name: "silent acceptance alone never votes (ENG-R877)",
            signals: repeated(weak(.english, .afterEnglish), 200) + repeated(weak(.vietnamese, .afterVietnamese), 200),
            votes: [("as", .afterEnglish, nil), ("as", .afterVietnamese, nil), ("as", nil, nil)],
            lookups: [("as", .afterEnglish, nil), ("as", .afterVietnamese, nil)]),
    ]

    /// The ratio against the other side and the conflict.
    static let conflicts: [Case] = [
        Case(
            name: "two corrections beat two acceptances of the other side (2 >= 3 x 0.5)",
            signals: repeated(strong(.english, .afterEnglish), 2) + repeated(weak(.vietnamese, .afterEnglish), 2),
            votes: [("as", .afterEnglish, .english)], lookups: [("as", .afterEnglish, .english)]),
        Case(
            name:
                "three acceptances of the other side stop two corrections (2 < 3 x 0.75); no correction there: no vote",
            signals: repeated(strong(.english, .afterEnglish), 2) + repeated(weak(.vietnamese, .afterEnglish), 3),
            votes: [("as", .afterEnglish, nil)], lookups: [("as", .afterEnglish, nil)]),
        Case(
            name: "corrections on both sides and no winner: conflict, the rules decide",
            signals: repeated(strong(.english, .afterEnglish), 2) + repeated(strong(.vietnamese, .afterEnglish), 2),
            votes: [("as", .afterEnglish, .conflict), ("as", nil, .conflict)], lookups: [("as", .afterEnglish, nil)]),
        Case(
            name: "six corrections beat two of the other side (6 >= 3 x 2)",
            signals: repeated(strong(.vietnamese, .afterVietnamese), 6)
                + repeated(strong(.english, .afterVietnamese), 2),
            votes: [("as", .afterVietnamese, .vietnamese)], lookups: [("as", .afterVietnamese, .vietnamese)]),
        Case(
            name: "the other side's acceptances count up to 64",
            signals: repeated(strong(.english, .afterEnglish), 49) + repeated(weak(.vietnamese, .afterEnglish), 100),
            votes: [("as", .afterEnglish, .english)], lookups: [("as", .afterEnglish, .english)]),
    ]

    /// The any-context entry and the lookup order.
    static let anyContext: [Case] = [
        Case(
            name: "corrections from two classes: the any-context entry votes and reaches a third class",
            signals: [strong(.english, .afterEnglish), strong(.english, .sentenceStart)],
            votes: [("as", .afterEnglish, nil), ("as", .sentenceStart, nil), ("as", nil, .english)],
            lookups: [("as", .afterNeutral, .english), ("as", .afterEnglish, .english)]),
        Case(
            name: "one correction toward the other side keeps the any-context entry silent",
            signals: [
                strong(.english, .afterEnglish), strong(.english, .sentenceStart), strong(.english, .afterNeutral),
                strong(.vietnamese, .afterVietnamese),
            ],
            votes: [("as", nil, .conflict), ("as", .afterVietnamese, nil)],
            lookups: [("as", .afterNeutral, nil), ("as", .afterVietnamese, nil)]),
        Case(
            name: "a class entry in conflict: the rules decide in that class while another class votes",
            signals: repeated(strong(.english, .afterEnglish), 2) + repeated(strong(.vietnamese, .afterEnglish), 2)
                + repeated(strong(.english, .sentenceStart), 2) + repeated(strong(.english, .afterNeutral), 8),
            votes: [("as", .afterEnglish, .conflict), ("as", .sentenceStart, .english), ("as", nil, .conflict)],
            lookups: [("as", .afterEnglish, nil), ("as", .sentenceStart, .english), ("as", .afterVietnamese, nil)]),
        Case(
            name: "acceptances of the other side stop the any-context entry too",
            signals: [strong(.vietnamese, .afterVietnamese), strong(.vietnamese, .afterNeutral)]
                + repeated(weak(.english, .afterVietnamese), 3),
            votes: [("as", .afterVietnamese, nil), ("as", nil, nil)],
            lookups: [("as", .afterVietnamese, nil), ("as", .afterNeutral, nil)]),
        Case(
            name: "words are separate",
            signals: repeated(strong(.english, .afterEnglish), 2)
                + repeated(strong(.vietnamese, .afterEnglish, word: "car"), 2),
            votes: [("as", .afterEnglish, .english), ("car", .afterEnglish, .vietnamese)],
            lookups: [
                ("as", .afterEnglish, .english), ("car", .afterEnglish, .vietnamese), ("its", .afterEnglish, nil),
            ]),
    ]
}
