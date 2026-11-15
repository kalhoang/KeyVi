// SPDX-License-Identifier: MPL-2.0
//
// Public API of the collision decisions: words that are both English and Vietnamese (spec/01-engine.md 8.1
// rules L9a to L9c, ENG-R825 to ENG-R829) and the learned memory the host keeps for them (ENG-R863 to
// ENG-R866). Part of the contract of PublicAPI.swift: do not change a public signature without updating
// docs/architecture/contracts.md and every caller.

/// The kind of the Vietnamese reading of an ambiguity row (`viKind`, ENG-R827), read by the revision rules
/// RV3 and RV4 (ENG-R828).
public enum VietnameseReadingKind: Sendable, Hashable {
    /// A sentence-final particle (`á`, `há`): never restored because an English function word follows.
    case particle
    /// A pronoun or function word (`bên`, `cả`, `đi`).
    case function
    /// Anything else (nouns, verbs, adjectives). The default for a row without a kind.
    case content
}

/// English multiword expressions of two to four words that contain a collision word (ENG-R826), matched on
/// lowercased raw keys. Lookups are constant time and allocate nothing: each word of the list has a number
/// and every prefix of two or more words is stored as one packed integer.
public struct PhraseList: Sendable {
    /// The most words in a phrase.
    static let maximumWords = 4
    /// Word -> number from 1 (0 means "in no phrase").
    let vocabulary: [String: UInt16]
    /// Every prefix of two to four words of a phrase, packed by `PhraseWords`.
    let prefixes: Set<UInt64>
    /// The number of phrases kept.
    public let count: Int

    /// A list from phrases written as lowercase words separated by one space. A phrase of fewer than two or
    /// more than four words is ignored, and so is any phrase once 65,535 distinct words are numbered.
    public init<S: Sequence>(_ phrases: S) where S.Element == String {
        var vocabulary: [String: UInt16] = [:]
        var prefixes = Set<UInt64>()
        var count = 0
        for phrase in phrases {
            let words = phrase.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 2, words.count <= Self.maximumWords else { continue }
            let newWords = Set(words.filter { vocabulary[$0] == nil })
            guard vocabulary.count + newWords.count <= Int(UInt16.max) else { continue }
            var packed = PhraseWords()
            for word in words {
                let number: UInt16
                if let known = vocabulary[word] {
                    number = known
                } else {
                    number = UInt16(vocabulary.count + 1)
                    vocabulary[word] = number
                }
                packed.append(number)
                if packed.count >= 2 { prefixes.insert(packed.key) }
            }
            count += 1
        }
        self.vocabulary = vocabulary
        self.prefixes = prefixes
        self.count = count
    }

    /// No phrases.
    public static let empty = PhraseList([String]())

    /// The number of `word` in the list, 0 when no phrase contains it.
    package func number(of word: String) -> UInt16 { vocabulary.isEmpty ? 0 : vocabulary[word] ?? 0 }

    /// The words are the first two to four words of a phrase.
    package func startsPhrase(_ words: PhraseWords?) -> Bool {
        guard let words, words.count >= 2 else { return false }
        return prefixes.contains(words.key)
    }
}

/// The bundled lists of the collision rules (spec 8.2, ENG-R825 to ENG-R828), built by lexicon-builder from
/// pinned inputs (ENG-R810) and reviewed by the product owner. Every word is lowercase.
public struct CollisionLists: Sendable {
    /// English phrases (L9b, RV1).
    public var phrases: PhraseList
    /// English and tech words outside the English lexicon whose Telex display is an attested syllable
    /// (`cos`, `gif`): on the collision list for the memory only, never restored by a rule (ENG-R863).
    public var supplement: WordSet
    /// Words that keep their Vietnamese display before `.`, `!`, `?` or Return (L9a; v1: `as`).
    public var boundaryParticles: WordSet
    /// Ambiguity rows marked `run: vi`: rule L10 never restores them (ENG-R827).
    public var runExempt: WordSet
    /// The kind of the Vietnamese reading of each ambiguity row (`viKind`); a missing row is `content`.
    public var readingKinds: [String: VietnameseReadingKind]
    /// Closed-class English words (RV3, RV4).
    public var englishFunctionWords: WordSet
    /// Valid Vietnamese syllables that are rare as unmarked Vietnamese in chat (`the`, `my`): English
    /// evidence for the window when typed unchanged (ENG-R823).
    public var englishLean: WordSet
    /// Vietnamese words that end a clause after an English phrase (`rồi`, `quá`; RV4 never fires on them).
    public var tailWords: WordSet
    /// The particles among the tail words (`nha`, `à`; RV2).
    public var tailParticles: WordSet
    /// Determiners, pronouns and auxiliaries: a word after one of them is inside an English phrase (RV4).
    public var preGuard: WordSet

    /// Lists; every argument defaults to empty.
    public init(
        phrases: PhraseList = .empty, supplement: WordSet = WordSet([]), boundaryParticles: WordSet = WordSet([]),
        runExempt: WordSet = WordSet([]), readingKinds: [String: VietnameseReadingKind] = [:],
        englishFunctionWords: WordSet = WordSet([]), englishLean: WordSet = WordSet([]),
        tailWords: WordSet = WordSet([]), tailParticles: WordSet = WordSet([]), preGuard: WordSet = WordSet([])
    ) {
        self.phrases = phrases
        self.supplement = supplement
        self.boundaryParticles = boundaryParticles
        self.runExempt = runExempt
        self.readingKinds = readingKinds
        self.englishFunctionWords = englishFunctionWords
        self.englishLean = englishLean
        self.tailWords = tailWords
        self.tailParticles = tailParticles
        self.preGuard = preGuard
    }

    /// No lists: rules L9a and L9b and the revision rules never match.
    public static let empty = CollisionLists()
}

/// The context of a collision word for the learned memory: the class of the previous token of the run
/// (ENG-R863).
public enum CollisionContext: Sendable, Hashable, CaseIterable {
    /// No previous token in the run (line start, after Return or Tab, after a reset), or the previous token
    /// was followed by `.`, `!`, `?` or `:`.
    case sentenceStart
    /// The previous token is Vietnamese (ENG-R823).
    case afterVietnamese
    /// The previous token is English (ENG-R823).
    case afterEnglish
    /// The previous token is neutral (ENG-R823).
    case afterNeutral
}

/// What the learned memory says about a word in one context (ENG-R863). The host computes it from its
/// counters; the engine only reads it.
public enum CollisionVote: Sendable, Hashable {
    /// Restore the raw keys.
    case english
    /// Keep the Vietnamese display.
    case vietnamese
    /// Corrections on both sides and no winner: the rules decide, and a context entry in conflict also
    /// hides the any-context entry.
    case conflict
}

/// An immutable snapshot of the learned memory (ENG-R865): the host builds it and passes it in `Resources`;
/// the engine never mutates it (ENG-R1202) and rebuilds nothing.
public struct CollisionMemorySnapshot: Sendable, Hashable {
    /// One vote of the memory for a word of the bundled collision list.
    public struct Vote: Sendable, Hashable {
        /// The collision word, lowercased raw keys from the bundled list (ENG-R866).
        public var word: String
        /// The context of the entry; nil for the any-context entry.
        public var context: CollisionContext?
        /// The vote.
        public var choice: CollisionVote

        /// A vote.
        public init(word: String, context: CollisionContext?, choice: CollisionVote) {
            self.word = word
            self.context = context
            self.choice = choice
        }
    }

    /// The votes of one word: one slot per context and one for any context.
    struct Slots: Sendable, Hashable {
        var sentenceStart: CollisionVote?
        var afterVietnamese: CollisionVote?
        var afterEnglish: CollisionVote?
        var afterNeutral: CollisionVote?
        var anyContext: CollisionVote?

        subscript(context: CollisionContext?) -> CollisionVote? {
            get {
                switch context {
                case .sentenceStart: sentenceStart
                case .afterVietnamese: afterVietnamese
                case .afterEnglish: afterEnglish
                case .afterNeutral: afterNeutral
                case nil: anyContext
                }
            }
            set {
                switch context {
                case .sentenceStart: sentenceStart = newValue
                case .afterVietnamese: afterVietnamese = newValue
                case .afterEnglish: afterEnglish = newValue
                case .afterNeutral: afterNeutral = newValue
                case nil: anyContext = newValue
                }
            }
        }
    }

    let words: [String: Slots]

    /// A snapshot of `votes`; when two votes name the same word and context, the later one counts.
    public init<S: Sequence>(_ votes: S) where S.Element == Vote {
        var words: [String: Slots] = [:]
        for vote in votes { words[vote.word, default: Slots()][vote.context] = vote.choice }
        self.words = words
    }

    /// No votes: rule L9c never decides.
    public static let empty = CollisionMemorySnapshot([Vote]())

    /// The snapshot holds no vote.
    public var isEmpty: Bool { words.isEmpty }

    /// The decision for `word` in `context` (ENG-R863): the context entry first; a context entry in conflict
    /// means the rules decide; without a context entry, the any-context entry. Nil when the rules decide.
    public func vote(word: String, context: CollisionContext) -> Language? {
        guard let slots = words[word] else { return nil }
        switch slots[context] {
        case .english: return .english
        case .vietnamese: return .vietnamese
        case .conflict: return nil
        case nil: break
        }
        switch slots[nil] {
        case .english: return .english
        case .vietnamese: return .vietnamese
        case .conflict, nil: return nil
        }
    }
}

/// A learning signal for a word of the bundled collision list (ENG-R864). The engine stores nothing; the
/// host feeds its memory with it (ENG-R1202, ENG-R866).
public struct CollisionSignal: Sendable, Hashable {
    /// How much the signal counts.
    public enum Strength: Sendable, Hashable {
        /// A correction by the user: the restore toggle against the rules (also after Backspace re-opened
        /// the word), or the toggle that undoes a revision.
        case strong
        /// A decision of the rules that became final untouched: three later commits in the run, or Return
        /// or Tab.
        case weak
    }

    /// The collision word: lowercased raw keys, the string of the bundled list (ENG-R866).
    public var word: String
    /// The class of the previous token when the word was decided.
    public var context: CollisionContext
    /// The side the user chose or accepted.
    public var side: Language
    /// Correction or silent acceptance.
    public var strength: Strength

    /// A signal.
    public init(word: String, context: CollisionContext, side: Language, strength: Strength) {
        self.word = word
        self.context = context
        self.side = side
        self.strength = strength
    }
}

/// Why the previous token was revised when the current token committed (ENG-R828). Reason codes carry no
/// text (ENG-R1220).
public enum RevisionReason: Sendable, Hashable {
    /// RV1: the previous token and this one continue a bundled phrase; the previous token is restored.
    case phrase
    /// RV2: the previous token is a restored boundary particle and this one a Vietnamese tail particle; the
    /// previous token takes its Vietnamese display.
    case particleTail
    /// RV3: this token is an English function word; the previous token is restored.
    case nextEnglish
    /// RV4: this token is Vietnamese; the previous token, restored by the English run, takes its Vietnamese
    /// display.
    case nextVietnamese

    /// The revision restores the previous token's raw keys (otherwise it shows its Vietnamese display).
    var restores: Bool { self == .phrase || self == .nextEnglish }
}
