// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// The kinds of one-key typo of ENG-T52 and ENG-T57 (spec/01-engine.md 11A.5).
public enum TypoKind: String, CaseIterable, Sendable, CustomStringConvertible {
    /// Two neighbouring keys swapped (two different letters).
    case transposition
    /// One key left out.
    case omission
    /// One random letter `a` to `z` added anywhere.
    case insertion
    /// One key typed twice.
    case doubling
    /// One key replaced by a QWERTY neighbour (ENG-R1113).
    case neighbour

    public var description: String { rawValue }

    /// The four kinds of ENG-T57 (ENG-R1124: transposition, omission, insertion, neighbouring key).
    public static let vietnameseKinds: [TypoKind] = [.transposition, .omission, .insertion, .neighbour]
}

/// One random typo of a given kind per call, from a recorded seed (ENG-T52, ENG-T57). The edits are those of the
/// reference model (`spec/reference-model/correction_measure.py`, `typo`); the random sequence is this generator's
/// own, so the samples differ from the model's while the rates stay comparable.
public struct TypoGenerator: Sendable {
    private var generator: SeededGenerator
    private let neighbours: [UInt8: [UInt8]]

    /// A generator with `seed` and the neighbours table of ENG-R1113 (the bundled one, or the spec's literal).
    public init(seed: UInt64, neighbours: [Character: String]) {
        generator = SeededGenerator(seed: seed)
        var table: [UInt8: [UInt8]] = [:]
        for (letter, row) in neighbours { if let key = letter.asciiValue { table[key] = Array(row.utf8) } }
        self.neighbours = table
    }

    /// A uniformly chosen element of `words` (the samples of ENG-T52).
    public mutating func pick(_ words: [String]) -> String { generator.pick(words) }

    /// `count` distinct words of `words`, drawn without replacement (the 6,000 words per kind of ENG-T52).
    public mutating func sample(_ words: [String], count: Int) -> [String] {
        var pool = words
        let taken = min(count, pool.count)
        for index in 0..<taken { pool.swapAt(index, index + generator.nextInt(below: pool.count - index)) }
        return Array(pool.prefix(taken))
    }

    /// `word` with one edit of `kind` on its ASCII keys, nil when the word allows none: a transposition needs two
    /// different neighbouring letters, a neighbouring key a letter of the table.
    public mutating func typo(of word: String, kind: TypoKind) -> String? {
        var keys = Array(word.utf8)
        guard !keys.isEmpty else { return nil }
        switch kind {
        case .transposition:
            let places = keys.indices.dropLast().filter { keys[$0] != keys[$0 + 1] }
            guard !places.isEmpty else { return nil }
            let place = generator.pick(places)
            keys.swapAt(place, place + 1)
        case .omission:
            keys.remove(at: generator.nextInt(below: keys.count))
        case .insertion:
            let letter = UInt8(ascii: "a") + UInt8(generator.nextInt(below: 26))
            keys.insert(letter, at: generator.nextInt(below: keys.count + 1))
        case .doubling:
            let place = generator.nextInt(below: keys.count)
            keys.insert(keys[place], at: place)
        case .neighbour:
            let place = generator.nextInt(below: keys.count)
            guard let row = neighbours[keys[place]], !row.isEmpty else { return nil }
            keys[place] = generator.pick(row)
        }
        return String(decoding: keys, as: UTF8.self)
    }
}

/// Types words or texts with the typo correction on and reports what was corrected (ENG-T51 to ENG-T53, ENG-T57).
public enum CorrectionCheck {
    /// Types each word of `words` in a session continued from the state after `prefix` (`vieejt ` for a word after
    /// a Vietnamese word, ` ` for a word after a space, empty for the start of the input), commits it with a space
    /// and returns every word that a commit corrected, with the text left on screen for it (the field after the
    /// prefix, without the committing space).
    public static func corrections(
        of words: [String], resources: Resources, configuration: EngineConfiguration, after prefix: String = ""
    ) -> [ChangedWord] {
        outcomes(of: words, resources: resources, configuration: configuration, after: prefix).filter {
            if case .corrected? = $0.decision { true } else { false }
        }
    }

    /// The same for every word, in order: the text left on screen and the decision (a correction when a commit
    /// corrected the word, otherwise the last decision).
    public static func outcomes(
        of words: [String], resources: Resources, configuration: EngineConfiguration, after prefix: String = ""
    ) -> [ChangedWord] {
        var seeded = Session(engine: Engine(configuration: configuration, resources: resources))
        var seededField = SimulatedTextField()
        for key in prefix {
            let event = EngineEvent.key(KeyInput(key))
            try? seededField.apply(event, seeded.handle(event))
        }
        let prefixLength = seededField.text.count
        var outcomes: [ChangedWord] = []
        outcomes.reserveCapacity(words.count)
        for word in words {
            var session = seeded
            var field = seededField
            var decision: CommitDecision?
            var correction: CommitDecision?
            for key in word + " " {
                let event = EngineEvent.key(KeyInput(key))
                let output = session.handle(event)
                try? field.apply(event, output)
                if let made = output.decision { decision = made }
                if case .corrected? = output.decision { correction = output.decision }
            }
            let committed = String(field.text.dropFirst(prefixLength).dropLast())
            outcomes.append(ChangedWord(word: word, committed: committed, decision: correction ?? decision))
        }
        return outcomes
    }

    /// Types `keys` (characters; `\n` is Return) from an empty field and returns every token a commit corrected:
    /// its raw keys and the word left on screen (the field's last word before the committing key).
    public static func corrections(typing keys: String, resources: Resources, configuration: EngineConfiguration)
        -> [ChangedWord]
    {
        var session = Session(engine: Engine(configuration: configuration, resources: resources))
        var field = SimulatedTextField()
        var corrected: [ChangedWord] = []
        for key in keys {
            let event = EngineEvent.key(KeyInput(key))
            let raw = session.state.activeRawKeys
            let output = session.handle(event)
            try? field.apply(event, output)
            if case .corrected? = output.decision {
                let shown = field.text.dropLast().reversed().prefix { !$0.isWhitespace }.reversed()
                corrected.append(ChangedWord(word: raw, committed: String(shown), decision: output.decision))
            }
        }
        return corrected
    }

    /// The Telex keys of a Tier A or Tier B syllable in the usual order with the tone key last (ENG-T57; `ươ` as
    /// `uow`, as the reference model writes it), in the word's case pattern; nil for any other word.
    public static func telexKeysToneLast(_ word: String) -> String? {
        let analysis = Orthography.analyze(word.lowercased())
        guard analysis.validity != .invalid,
            let keys = KeySequenceGenerator.keys(
                onset: analysis.onset, rhyme: analysis.vowelGroup + analysis.coda, tone: analysis.tone,
                method: .telex, order: .o1)
        else { return nil }
        let letters = word.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return keys.uppercased() }
        if letters.first?.isUppercase == true { return keys.prefix(1).uppercased() + keys.dropFirst() }
        return keys
    }
}
