// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// One word whose committed text differs from the word typed.
public struct ChangedWord: Sendable, Hashable, CustomStringConvertible {
    /// The word as written in the source.
    public let word: String
    /// The text the engine left on screen for it.
    public let committed: String
    /// The decision of the commit that ended the word, if any.
    public let decision: CommitDecision?
    /// The word, its committed text and the decision.
    public var description: String { "\(word) -> \(committed) (\(decision.map { "\($0)" } ?? "no decision"))" }
}

/// The English corpus targets of spec 8.8 (ENG-T10, ENG-T11): every word typed in Telex with default
/// options and committed by a space, (a) after an English seed token (English run, ENG-R871: at least
/// 99.5 % unchanged, every failure a known exception) and (b) after a Vietnamese seed token (ENG-R872: at
/// most 3 % changed, every change an ambiguity candidate of ENG-R820 whose row, if any, is `vi`).
///
/// `VietnameseEngineDataTests` runs it over the bundled lexicon and tech lists (`EnglishCorpusGateTests`);
/// the engine tests run it with the 13.9 fixtures.
public struct EnglishCorpusReport: Sendable {
    /// Number of words checked.
    public let words: Int
    /// Words changed after the English seed token (ENG-R871).
    public let changedInEnglishRun: [ChangedWord]
    /// Words changed after the Vietnamese seed token (ENG-R872).
    public let changedInVietnameseContext: [ChangedWord]

    /// ENG-R871: the share of words unchanged in an English run, known exceptions not counted as failures.
    public func unchangedShareInEnglishRun(exceptions: Set<String>) -> Double {
        guard words > 0 else { return 1 }
        return Double(words - changedInEnglishRun.filter { !exceptions.contains($0.word) }.count) / Double(words)
    }

    /// ENG-R872: the share of words changed in Vietnamese context.
    public var changedShareInVietnameseContext: Double {
        words > 0 ? Double(changedInVietnameseContext.count) / Double(words) : 0
    }

    /// ENG-R872: changes in Vietnamese context that are not an ambiguity candidate (ENG-R820: the display
    /// is an attested Tier A syllable) with a `vi` decision (reviewed or unreviewed, ENG-R821).
    public func unexplainedVietnameseChanges(resources: Resources) -> [ChangedWord] {
        changedInVietnameseContext.filter { change in
            let display = change.committed.lowercased()
            let candidate =
                Orthography.validity(of: display) == .standard && resources.attestedSyllables.contains(display)
            let row = resources.ambiguity[change.word.lowercased()]
            return !candidate || row == .english
        }
    }
}

/// Runs the English corpus check of ENG-T10.
public enum EnglishCorpusCheck {
    /// Types every word after each seed and reports the words whose committed text changed. `configuration`
    /// defaults to the spec's defaults (Telex, collision rules on, ENG-R829).
    public static func run(
        words: [String], resources: Resources, configuration: EngineConfiguration = EngineConfiguration(),
        englishSeed: String = "and", vietnameseSeed: String = "vieejt"
    ) -> EnglishCorpusReport {
        let engine = Engine(configuration: configuration, resources: resources)
        func changes(after seed: String) -> [ChangedWord] {
            var session = Session(engine: engine)
            for key in seed + " " { _ = session.handle(.key(KeyInput(key))) }
            let seeded = session.state
            var changed: [ChangedWord] = []
            for word in words {
                var probe = Session(engine: engine, state: seeded)
                var field = SimulatedTextField()
                var decision: CommitDecision?
                for key in word + " " {
                    let event = EngineEvent.key(KeyInput(key))
                    let output = probe.handle(event)
                    try? field.apply(event, output)
                    if let made = output.decision { decision = made }
                }
                let committed = String(field.string.dropLast())
                if committed != word {
                    changed.append(ChangedWord(word: word, committed: committed, decision: decision))
                }
            }
            return changed
        }
        return EnglishCorpusReport(
            words: words.count, changedInEnglishRun: changes(after: englishSeed),
            changedInVietnameseContext: changes(after: vietnameseSeed))
    }

    /// `known-exceptions.txt` (ENG-T11): one exception per line, `word<TAB>display<TAB>rule<TAB>reason`;
    /// `#` starts a comment. Returns the words.
    public static func exceptions(_ text: String) -> Set<String> {
        var words = Set<String>()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            if let word = line.split(separator: "\t").first, !word.isEmpty { words.insert(String(word)) }
        }
        return words
    }
}

/// The Vietnamese prose target of spec 8.8 (ENG-T20, ENG-R873): every token of a text typed by three
/// simulated typists and committed in Vietnamese context; at least 99.95 % of tokens identical to the
/// source, every difference attributable to an `en` ambiguity row.
///
/// Typists (ENG-T20 "canonical, tone at end, free order with modifiers after the coda"): O2 (each mark as
/// soon as its letter is typed, the tone right after the vowel group), O1 (tone key last) and O3 (letters
/// first, then stroke, modifiers and tone after the coda). Syllables are spelled by the oracle's key
/// generator from `Orthography.analyze`; words that are not Tier A syllables are typed as they are.
public enum ProseCorpusCheck {
    /// The result of one typist over one text.
    public struct Report: Sendable {
        /// Number of words typed.
        public let tokens: Int
        /// Words whose typed result differs from the source.
        public let differences: [ChangedWord]
        /// Commits that revised the previous word (ENG-R828); the W11 prose gate expects none.
        public let revisions: Int
        /// The share of words typed exactly (ENG-R873).
        public var identicalShare: Double {
            tokens > 0 ? Double(tokens - differences.count) / Double(tokens) : 1
        }
    }

    /// The three typists of ENG-T20, in the order canonical, tone at end, free order.
    public static let typists: [CorpusOrder] = [.o2, .o1, .o3]

    /// Types `text` with `order` in `method` and compares each word with the source. `style` is the typist's
    /// tone-style setting (spec 5.2); the keys are the same in both styles, only the placement differs.
    /// `lookaheadRevision` is the configuration switch of the collision rules (ENG-R829); `appContext` is the
    /// host's app context (ENG-R850).
    public static func run(
        text: String, method: CorpusMethod, order: CorpusOrder, style: ToneStyle = .traditional,
        lookaheadRevision: Bool = true, appContext: AppContext = .general, resources: Resources
    ) -> Report {
        let configuration = EngineConfiguration(
            inputMethod: method.inputMethod, toneStyle: style, appContext: appContext,
            lookaheadRevision: lookaheadRevision)
        let engine = Engine(configuration: configuration, resources: resources)
        var session = Session(engine: engine)
        var tokens = 0
        var revisions = 0
        var differences: [ChangedWord] = []
        for (word, separator) in split(text) {
            var field = SimulatedTextField()
            var decision: CommitDecision?
            for key in keys(for: word, method: method, order: order) + separator {
                let event = EngineEvent.key(KeyInput(key))
                let output = session.handle(event)
                try? field.apply(event, output)
                if let made = output.decision { decision = made }
                if output.revision != nil { revisions += 1 }
            }
            guard !word.isEmpty else { continue }
            tokens += 1
            let typed = String(field.string.dropLast(separator.count))
            if typed != word { differences.append(ChangedWord(word: word, committed: typed, decision: decision)) }
        }
        return Report(tokens: tokens, differences: differences, revisions: revisions)
    }

    /// The keys that type `word`: the generated sequence for a Tier A syllable, in the word's case
    /// pattern (lowercase, capitalised or all capitals), otherwise the word itself.
    public static func keys(for word: String, method: CorpusMethod, order: CorpusOrder) -> String {
        let analysis = Orthography.analyze(word)
        guard analysis.validity == .standard,
            let keys = KeySequenceGenerator.keys(
                onset: analysis.onset, rhyme: analysis.vowelGroup + analysis.coda, tone: analysis.tone, method: method,
                order: order == .o4 ? .o1 : order)
        else { return word }
        let letters = word.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return keys.uppercased() }
        if letters.first?.isUppercase == true { return keys.prefix(1).uppercased() + keys.dropFirst() }
        return keys
    }

    /// Words (runs of letters) with the separators that follow them.
    static func split(_ text: String) -> [(word: String, separator: String)] {
        var result: [(String, String)] = []
        var word = ""
        var separator = ""
        for character in text {
            if character.isLetter {
                if !separator.isEmpty {
                    result.append((word, separator))
                    word = ""
                    separator = ""
                }
                word.append(character)
            } else {
                separator.append(character)
            }
        }
        if !word.isEmpty || !separator.isEmpty { result.append((word, separator)) }
        return result
    }
}
