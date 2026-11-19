// SPDX-License-Identifier: MPL-2.0
//
// The memory simulation of ENG-R877 (QA-R68): a scripted user types the corpus in shuffled passes. The engine
// reads a snapshot of `ReferenceCollisionMemory` (ENG-R865), rebuilt after every sentence because each sentence ends
// with Return, a hard boundary at which the host may swap the snapshot (ENG-R1211). Accuracy is measured on what
// the engine commits before the user reviews the sentence. The user who corrects then fixes every wrong collision
// through the engine itself, as a person would, so the memory learns only from the signals the engine emits
// (ENG-R864): Backspace, Escape and the boundary key again right after the commit (ENG-R704); Escape on the active
// word before Return, which can only give the English side (ENG-R701); Escape right after the commit that revised
// the word (ENG-R829). A word whose correction needs the field after Return (a sent chat line) stays as it is. The
// user who never corrects only accepts silently: the engine's weak signals reach the memory and nothing else.

import VietnameseEngine
import VietnameseEngineTesting

/// The scripted user.
enum ScriptedUser {
    case correctsEveryError
    case neverCorrects
}

/// The result of one pass over a set of sentences.
struct PassResult {
    var collisions = LanguagePair()
    /// Collisions the memory decided (L9c), right and wrong.
    var memoryDecisions = Tally()
    /// Hidden collisions (`có` typed `cos`) the memory turned into English.
    var hiddenDamaged = 0
    /// Words that are not collisions and differ from the frozen output without memory.
    var nonCollisionChanges = 0
    var corrections = 0
    var uncorrectable = 0
    var entries = 0
    var votingEntries = 0
    /// Signals whose word is not on the bundled collision list (ENG-R866).
    var foreignSignals = 0
    /// Sentences whose words, tokens and fixture words did not line up (a harness or fixture problem).
    var misaligned = 0
}

/// Passes of the scripted user over fixture sentences.
struct MemorySimulation {
    let resources: Resources
    let user: ScriptedUser

    /// One pass: every sentence in `order`, learning from each. Returns the pass's numbers and the memory after it.
    func pass(_ order: [CorpusSentence], memory start: ReferenceCollisionMemory) throws
        -> (result: PassResult, memory: ReferenceCollisionMemory)
    {
        var memory = start
        var result = PassResult()
        for sentence in order {
            let replay = HostReplay(engine: engine(memory.snapshot))
            let inputs = try HostInput.parse(sentence.keys)
            let plain = try replay.run(inputs)
            result = Self.scored(plain, sentence, into: result)
            let reviewed = try review(sentence, inputs: inputs, replay: replay, plain: plain)
            result.corrections += reviewed.corrected
            result.uncorrectable += reviewed.missed
            result.foreignSignals += reviewed.result.signals.filter { !isListWord($0.word) }.count
            memory = memory.recording(reviewed.result.signals)
        }
        result.entries = memory.entries.count
        result.votingEntries = memory.votingEntryCount
        return (result, memory)
    }

    /// The numbers of `sentences` with `memory` frozen (no learning): the held-out evaluation.
    func evaluate(_ sentences: [CorpusSentence], memory: ReferenceCollisionMemory) throws -> PassResult {
        let replay = HostReplay(engine: engine(memory.snapshot))
        return try sentences.reduce(PassResult()) { result, sentence in
            Self.scored(try replay.run(try HostInput.parse(sentence.keys)), sentence, into: result)
        }
    }

    private func engine(_ snapshot: CollisionMemorySnapshot) -> Engine {
        var withMemory = resources
        withMemory.collisionMemory = snapshot
        return Engine(configuration: EngineConfiguration(typoCorrection: false), resources: withMemory)
    }

    private func isListWord(_ word: String) -> Bool {
        resources.ambiguity[word] != nil || resources.collision.supplement.contains(word)
    }

    private static func scored(_ replay: ReplayResult, _ sentence: CorpusSentence, into start: PassResult) -> PassResult
    {
        var result = start
        let words = replay.words
        let frozen = Self.wordsOfNotation(sentence.expected)
        guard words.count == sentence.words.count, replay.tokens.count == words.count else {
            result.misaligned += 1
            return result
        }
        for (index, word) in sentence.words.enumerated() {
            let ok = words[index] == word.intended
            switch word.label {
            case .plain:
                if index < frozen.count, words[index] != frozen[index] { result.nonCollisionChanges += 1 }
            case .hidden:
                if !ok { result.hiddenDamaged += 1 }
            case .collision(let intended, _, _):
                result.collisions = result.collisions.adding(ok, intended: intended)
            }
            if case .kept(.learned) = replay.tokens[index].decision {
                result.memoryDecisions = result.memoryDecisions.adding(ok)
            } else if case .restored(.learned) = replay.tokens[index].decision {
                result.memoryDecisions = result.memoryDecisions.adding(ok)
            }
        }
        return result
    }

    /// The user's review of one sentence: the first wrong collision after the last one handled is corrected, the
    /// sentence is replayed with every correction so far, and so on to the end (a correction changes the words after
    /// it). A correction that does not give the intended word is dropped and counted as missed.
    private func review(_ sentence: CorpusSentence, inputs: [HostInput], replay: HostReplay, plain: ReplayResult)
        throws -> (result: ReplayResult, corrected: Int, missed: Int)
    {
        guard user == .correctsEveryError else { return (plain, 0, 0) }
        var plan: Set<Correction> = []
        var current = plain
        var corrected = 0
        var missed = 0
        var from = 0
        while let index = Self.firstError(current, sentence, from: from) {
            from = index + 1
            guard let correction = Self.correction(for: index, in: current, sentence) else {
                missed += 1
                continue
            }
            let candidate = try replay.run(inputs, corrections: plan.union([correction]))
            let words = candidate.words
            if words.count == sentence.words.count, candidate.tokens.count == words.count,
                words[index] == sentence.words[index].intended
            {
                plan.insert(correction)
                current = candidate
                corrected += 1
            } else {
                missed += 1
            }
        }
        return (current, corrected, missed)
    }

    private static func firstError(_ replay: ReplayResult, _ sentence: CorpusSentence, from: Int) -> Int? {
        let words = replay.words
        guard words.count == sentence.words.count, replay.tokens.count == words.count else { return nil }
        return sentence.words.indices.first { index in
            index >= from && sentence.words[index].label != .plain && words[index] != sentence.words[index].intended
        }
    }

    private static func correction(for index: Int, in replay: ReplayResult, _ sentence: CorpusSentence)
        -> Correction?
    {
        let token = replay.tokens[index]
        let endsLine: (Character) -> Bool = { $0 == "\n" || $0 == "\t" }
        if token.revision != nil {
            // The undo must follow the revising commit at once; after Return or Tab the toggle passes through.
            guard index + 1 < replay.tokens.count, !endsLine(replay.tokens[index + 1].boundary) else { return nil }
            return .undoRevision(index)
        }
        guard endsLine(token.boundary) else { return .afterCommit(index) }
        guard case .collision(.english, _, _) = sentence.words[index].label else { return nil }
        return .beforeBoundary(index)
    }
}

extension MemorySimulation {
    /// The words of a field written in fixture notation: runs of letters, a `{...}` key name counts as a separator.
    static func wordsOfNotation(_ notation: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inKeyName = false
        for character in notation {
            if character == "{" { inKeyName = true }
            if !inKeyName, character.isLetter {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
            if character == "}" { inKeyName = false }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
