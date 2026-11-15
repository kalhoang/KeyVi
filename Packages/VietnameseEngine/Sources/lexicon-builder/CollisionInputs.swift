// SPDX-License-Identifier: MPL-2.0
//
// The collision lists (spec/01-engine.md 8.2, ENG-R825 to ENG-R828, ENG-R863): hand-written inputs under
// data/inputs/, reviewed by the product owner, written to the resources as sorted word lists. The build checks
// that every phrase's Vietnamese reading is absent from the prose corpus and that every supplement word types
// as its listed display, which must be attested while the raw keys are not English.

import Foundation
import VietnameseEngine

/// The parsed collision inputs.
struct CollisionInputs {
    static let phrasesFile = "phrases.txt"
    static let supplementFile = "collision-supplement.txt"
    static let boundaryParticlesFile = "boundary-particles.txt"
    static let functionWordsFile = "english-function-words.txt"
    static let englishLeanFile = "english-lean-neutral.txt"
    static let tailWordsFile = "vi-tail-words.txt"
    static let preGuardFile = "english-pre-guard.txt"

    var phrases: [String] = []
    var supplement: [(raw: String, display: String)] = []
    var boundaryParticles: [String] = []
    var functionWords: [String] = []
    var englishLean: [String] = []
    var tailWords: [(word: String, isParticle: Bool)] = []
    var preGuard: [String] = []

    static func load(_ layout: Layout) throws -> CollisionInputs {
        func url(_ name: String) -> URL { layout.inputs.appendingPathComponent(name) }
        var inputs = CollisionInputs()
        inputs.phrases = try CollisionList.phrases(url(phrasesFile))
        inputs.supplement = try CollisionList.supplement(url(supplementFile))
        inputs.boundaryParticles = try CollisionList.words(url(boundaryParticlesFile))
        inputs.functionWords = try CollisionList.words(url(functionWordsFile))
        inputs.englishLean = try CollisionList.words(url(englishLeanFile))
        inputs.tailWords = try CollisionList.tailWords(url(tailWordsFile))
        inputs.preGuard = try CollisionList.words(url(preGuardFile))
        return inputs
    }
}

/// Parsers of the collision inputs; a malformed line fails with the file name and line number.
enum CollisionList {
    static func isLowercaseWord(_ word: Substring) -> Bool {
        !word.isEmpty && word.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A }
    }

    /// One lowercase word a-z per line, unique.
    static func words(_ url: URL) throws -> [String] {
        var seen = Set<String>()
        for (number, line) in FileIO.contentLines(try FileIO.readUTF8(url)) {
            guard isLowercaseWord(Substring(line)) else {
                throw BuilderError("\(url.lastPathComponent) line \(number): '\(line)' must be one lowercase word a-z")
            }
            guard seen.insert(line).inserted else {
                throw BuilderError("\(url.lastPathComponent) line \(number): duplicate '\(line)'")
            }
        }
        return utf8Sorted(seen)
    }

    /// Phrases of 2 to 4 lowercase words a-z separated by one space, unique (ENG-R826).
    static func phrases(_ url: URL) throws -> [String] {
        var seen = Set<String>()
        for (number, line) in FileIO.contentLines(try FileIO.readUTF8(url)) {
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            guard (2...4).contains(words.count), words.allSatisfy(isLowercaseWord) else {
                throw BuilderError(
                    "\(url.lastPathComponent) line \(number): '\(line)' must be 2 to 4 lowercase words a-z "
                        + "separated by one space")
            }
            guard seen.insert(line).inserted else {
                throw BuilderError("\(url.lastPathComponent) line \(number): duplicate '\(line)'")
            }
        }
        return utf8Sorted(seen)
    }

    /// `raw<TAB>display` lines: raw keys a-z, display lowercase NFC Vietnamese letters; raw keys unique.
    static func supplement(_ url: URL) throws -> [(raw: String, display: String)] {
        var rows: [String: String] = [:]
        for (number, line) in FileIO.dataLines(try FileIO.readUTF8(url)) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, isLowercaseWord(fields[0]), isVietnameseWord(String(fields[1])) else {
                throw BuilderError(
                    "\(url.lastPathComponent) line \(number): expected '<raw a-z><TAB><lowercase Vietnamese display>'")
            }
            guard rows.updateValue(String(fields[1]), forKey: String(fields[0])) == nil else {
                throw BuilderError("\(url.lastPathComponent) line \(number): duplicate '\(fields[0])'")
            }
        }
        return rows.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map { ($0.key, $0.value) }
    }

    /// `word<TAB>particle|word` lines: lowercase NFC Vietnamese words, unique.
    static func tailWords(_ url: URL) throws -> [(word: String, isParticle: Bool)] {
        var rows: [String: Bool] = [:]
        for (number, line) in FileIO.dataLines(try FileIO.readUTF8(url)) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, isVietnameseWord(fields[0]), fields[1] == "particle" || fields[1] == "word"
            else {
                throw BuilderError(
                    "\(url.lastPathComponent) line \(number): expected '<lowercase Vietnamese word><TAB>particle|word'")
            }
            guard rows.updateValue(fields[1] == "particle", forKey: fields[0]) == nil else {
                throw BuilderError("\(url.lastPathComponent) line \(number): duplicate '\(fields[0])'")
            }
        }
        return rows.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map { ($0.key, $0.value) }
    }

    static func isVietnameseWord(_ word: String) -> Bool {
        !word.isEmpty && VietnameseText.isNFC(word)
            && word.unicodeScalars.elementsEqual(word.lowercased().unicodeScalars)
            && word.allSatisfy(VietnameseText.isVietnameseLetter)
    }
}

/// The build checks of the collision lists.
enum CollisionChecks {
    /// ENG-R826, the W11 audit: a phrase whose Vietnamese reading (each word typed in Telex, traditional style)
    /// occurs as a word sequence in the prose corpus would restore real Vietnamese, so the build fails. Phrases
    /// whose words all stay as typed have no Vietnamese reading. `corpus` is the text of
    /// data/corpus/prose-vi.txt (header lines start with `#`).
    static func checkPhrases(_ phrases: [String], corpus: String, typer: some CandidateTyper) throws {
        var readings: [(phrase: String, words: [String])] = []
        for phrase in phrases {
            let words = phrase.split(separator: " ").map(String.init)
            let reading = words.map { typer.display(typing: $0, method: .telex, style: .traditional).lowercased() }
            if reading != words { readings.append((phrase, reading)) }
        }
        let firstWords = Set(readings.map { $0.words[0] })
        var tokens: [String] = []
        var positions: [String: [Int]] = [:]
        for line in corpus.split(separator: "\n") where !line.hasPrefix("#") {
            for token in line.split(separator: " ") {
                let word = token.lowercased()
                if firstWords.contains(word) { positions[word, default: []].append(tokens.count) }
                tokens.append(word)
            }
            tokens.append("")  // paragraphs never join into one sequence
        }
        var found: [String] = []
        for (phrase, words) in readings {
            let occurs = (positions[words[0]] ?? []).contains { start in
                start + words.count <= tokens.count && Array(tokens[start..<start + words.count]) == words
            }
            if occurs { found.append("\(phrase) (\(words.joined(separator: " ")))") }
        }
        guard found.isEmpty else {
            throw BuilderError(
                "phrases.txt: the Vietnamese reading of these phrases occurs in data/corpus/prose-vi.txt (remove "
                    + "them or justify a change of the check):\n" + found.joined(separator: "\n"))
        }
    }

    /// ENG-R863: a supplement word must not be English (it would be an ambiguity candidate instead), and the
    /// engine must type it as its listed display, an attested syllable.
    static func checkSupplement(
        _ rows: [(raw: String, display: String)], english: [String: Int], techAlways: Set<String>,
        attested: Set<String>, typer: some CandidateTyper
    ) throws {
        var problems: [String] = []
        for (raw, display) in rows {
            if english[raw] != nil || techAlways.contains(raw) {
                problems.append("\(raw): is English (lexicon or tech-always); it belongs in ambiguity.tsv")
            }
            let typed = typer.display(typing: raw, method: .telex, style: .traditional)
            if typed != display { problems.append("\(raw): the engine types '\(typed)', the list says '\(display)'") }
            if !attested.contains(display) { problems.append("\(raw): display '\(display)' is not attested") }
        }
        guard problems.isEmpty else {
            throw BuilderError("collision-supplement.txt:\n" + problems.joined(separator: "\n"))
        }
    }
}
