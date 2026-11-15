// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Seeded random streams of collision words, separators, Backspace, toggles and resets through the
/// `InvariantChecker` (13.6), with the collision fixture and a memory, so that revisions and undos happen
/// often: every invariant holds after every event, and a revision never deletes more than the previous token,
/// one space and the current token (ENG-R828).
@Suite("Collision fuzz (ENG-R828, 13.6)")
struct CollisionFuzzTests {
    static let words = [
        "as", "hell", "car", "nha", "you", "is", "this", "been", "has", "tricky", "dduwowcj", "nhoms", "great",
        "job", "soon", "such", "cos", "if", "quas", "owr", "the", "tows", "and", "of", "course", "me", "too",
        "Car", "AS", "test", "toi",
        // Sequences that revise, so that revisions and their undo are frequent.
        "dduwowcj as hell", "tricky as nha", "if you", "great job car nhoms", "dduwowcj has been", "as soon as",
    ]
    static let separators = [" ", " ", " ", " ", ".", ",", "  ", "\n", "!", "\u{2014}"]

    @Test("Random collision streams keep every invariant", arguments: [0, 1, 2, 3])
    func randomStreams(_ seed: UInt64) throws {
        let memory = CollisionMemorySnapshot([
            .init(word: "car", context: .afterEnglish, choice: .vietnamese),
            .init(word: "cos", context: nil, choice: .english),
            .init(word: "this", context: .sentenceStart, choice: .english),
        ])
        for configuration in [EngineConfiguration(), EngineConfiguration(historyLimit: 2)] {
            let engine = Engine(configuration: configuration, resources: CollisionFixture.resources(memory: memory))
            var options = InvariantChecker.Options()
            options.nfcCheck = { $0.precomposedStringWithCanonicalMapping == $0 }
            options.pureReduceOneIn = 4
            var checker = InvariantChecker(engine: engine, options: options, probeSeed: 0xC011 &+ seed)
            var generator = SeededGenerator(seed: 0xC011_15E0 &+ seed)
            var revisions = 0
            var undos = 0
            for _ in 0..<4_000 {
                for event in Self.nextEvents(&generator) {
                    let output = try checker.send(event)
                    if output.revision != nil { revisions += 1 }
                    if event == .restoreToggle, !output.collisionSignals.isEmpty { undos += 1 }
                }
            }
            try checker.finish()
            print(
                "[ENG-R828] seed \(seed), history \(configuration.historyLimit): \(revisions) revisions, \(undos) undos"
            )
            #expect(revisions > 250, "the stream must exercise revisions (\(revisions))")
            #expect(undos > 20, "the stream must exercise undos (\(undos))")
        }
    }

    /// Words of the code context: the code-only `tar` at line starts (Return is a frequent separator) before
    /// Vietnamese words, options and file names, so that RV5 and its undo happen often, and in sentence case so that
    /// the sentence condition of L9 happens often (ENG-R850).
    static let codeWords = [
        "tar", "Tar", "TAR", "thuwr", "cais", "nayf", "xf", "anh", "sudo", "nhaatj", "log", "vieejt", "and",
        "Tar thuwr", "tar thuwr cais", "tar xf", "sudo tar", "tar nhaatj-kys.log", "anh.tar", "TAR thuwr",
    ]
    static let codeSeparators = [" ", " ", " ", "\n", "\n", ".", "-", ",", "  ", "!", "`", "\t", "\n# ", "\n  "]

    /// ENG-R828 RV5 and the sentence condition of L9 (ENG-R850) in the code context, in the terminal configuration
    /// (`lookaheadRevision` off, PLT-R357) and with every rule on, without and with `tar` on the capitalized code-word
    /// list: every invariant holds, the revision bound covers RV5, and L9 never restores a word that starts a sentence
    /// (the first word of its line, in sentence case, committed by a space, not on the list).
    @Test("Random code-context streams keep every invariant", arguments: [0, 1])
    func randomCodeStreams(_ seed: UInt64) throws {
        var capitalized = CollisionFixture.resources()
        capitalized.techCodeCapitalized = WordSet(["tar"])
        for (configuration, resources) in [
            (EngineConfiguration(appContext: .code, lookaheadRevision: false), CollisionFixture.resources()),
            (EngineConfiguration(appContext: .code, historyLimit: 2), CollisionFixture.resources()),
            (EngineConfiguration(appContext: .code, lookaheadRevision: false), capitalized),
        ] {
            let engine = Engine(configuration: configuration, resources: resources)
            var options = InvariantChecker.Options()
            options.nfcCheck = { $0.precomposedStringWithCanonicalMapping == $0 }
            options.pureReduceOneIn = 4
            var checker = InvariantChecker(engine: engine, options: options, probeSeed: 0xC0DE &+ seed)
            var generator = SeededGenerator(seed: 0xC0DE_15E0 &+ seed)
            var revisions = 0
            var sentences = 0
            for _ in 0..<4_000 {
                for event in Self.nextEvents(&generator, words: Self.codeWords, separators: Self.codeSeparators) {
                    let state = checker.session.state
                    let raw = state.activeRawKeys
                    let sentenceAtLineStart =
                        event == .key(KeyInput(" ")) && CommitPolicy.isLineStart(state.history)
                        && CommitPolicy.isSentenceCase(raw)
                    let output = try checker.send(event)
                    if output.revision == .lineVietnamese { revisions += 1 }
                    guard sentenceAtLineStart, let decision = output.decision, decision.rule != .userChoice else {
                        continue
                    }
                    sentences += 1
                    // L9 restores such a word exactly when it is a capitalized code word.
                    let listed = resources.techCodeCapitalized.contains(raw.lowercased())
                    #expect((decision == .restored(.codeContext)) == listed, "\(raw) at a line start: \(decision)")
                }
            }
            try checker.finish()
            print(
                "[ENG-R828, ENG-R850] seed \(seed), history \(configuration.historyLimit): \(revisions) RV5 revisions, "
                    + "\(sentences) words in sentence case at a line start")
            #expect(revisions > 50, "the stream must exercise RV5 (\(revisions))")
            #expect(sentences > 50, "the stream must exercise the sentence condition (\(sentences))")
        }
    }

    /// A word and a separator, sometimes followed by a toggle, a Backspace or a reset.
    static func nextEvents(
        _ generator: inout SeededGenerator, words: [String] = Self.words, separators: [String] = Self.separators
    ) -> [EngineEvent] {
        var events = KeyNotation.events(words[Int(generator.next() % UInt64(words.count))])
        events += KeyNotation.events(separators[Int(generator.next() % UInt64(separators.count))])
        switch generator.next() % 12 {
        case 0, 1: events.append(.restoreToggle)
        case 2: events.append(.backspace)
        case 3: events += [.backspace, .backspace, .restoreToggle]
        case 4: events.append(.reset(.unknown))
        default: break
        }
        return events
    }
}
