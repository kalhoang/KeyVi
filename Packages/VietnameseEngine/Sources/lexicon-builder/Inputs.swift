// SPDX-License-Identifier: MPL-2.0
//
// Parsers for the pinned inputs. Hand-edited files fail loudly with a file and line number.

import Foundation

enum EnglishLexicon {
    /// One-letter entries kept: the English words `a` and `I`. SCOWL also lists letters such as `m`;
    /// Vietnamese text uses lone consonants as list markers (`m)`) and chat abbreviations (`m` for mày), and
    /// rule ENG-R823 would make each of them an English token that turns the run English
    /// (docs/decisions/0202).
    static let oneLetterWords: Set<String> = ["a", "i"]

    /// Lowercase ASCII words of the selected SCOWL lists with their smallest size level, a legal
    /// frequency proxy (level 10 holds the most common words; spec/01-engine.md 8.2, ENG-R820).
    static func load(_ layout: Layout) throws -> [String: Int] {
        var levels: [String: Int] = [:]
        for category in Scowl.categories {
            for level in Scowl.levels {
                let url = layout.scowlDirectory.appendingPathComponent("\(category)-words.\(level)")
                // SCOWL 2020.12.07 lists are ISO-8859-1.
                guard let text = String(data: try FileIO.read(url), encoding: .isoLatin1) else {
                    throw BuilderError("\(url.path) is not ISO-8859-1")
                }
                for raw in text.split(whereSeparator: \.isNewline) {
                    let word = raw.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !word.isEmpty, word.utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { continue }
                    guard word.utf8.count > 1 || oneLetterWords.contains(word) else { continue }
                    levels[word] = min(levels[word] ?? level, level)
                }
            }
        }
        return levels
    }
}

enum TechList {
    /// Entries of a tech list: lowercase ASCII letters and digits with at least one letter, no duplicates.
    static func load(_ url: URL) throws -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for (number, word) in FileIO.contentLines(try FileIO.readUTF8(url)) {
            guard isValidEntry(word) else {
                throw BuilderError(
                    "\(url.lastPathComponent) line \(number): '\(word)' must be lowercase a-z/0-9 with a letter")
            }
            guard seen.insert(word).inserted else {
                throw BuilderError("\(url.lastPathComponent) line \(number): duplicate entry '\(word)'")
            }
            words.append(word)
        }
        return words
    }

    static func isValidEntry(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
            && word.utf8.contains { $0 >= 0x61 && $0 <= 0x7A }
    }
}

enum AttestedAdditions {
    /// `syllable<TAB>reason` lines; the reason is mandatory so every hand addition stays reviewable.
    static func load(_ url: URL) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let lines = try FileIO.readUTF8(url).split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = String(raw)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = line.split(separator: "\t", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let number = index + 1
            guard fields.count == 2, !fields[1].isEmpty else {
                throw BuilderError("attested-additions.txt line \(number): expected 'syllable<TAB>reason'")
            }
            let syllable = fields[0]
            guard VietnameseText.isNFC(syllable),
                syllable.unicodeScalars.elementsEqual(syllable.lowercased().unicodeScalars),
                !syllable.isEmpty,
                syllable.allSatisfy(VietnameseText.isVietnameseLetter)
            else {
                throw BuilderError(
                    "attested-additions.txt line \(number): '\(syllable)' must be lowercase NFC Vietnamese letters")
            }
            guard seen.insert(syllable).inserted else {
                throw BuilderError("attested-additions.txt line \(number): duplicate '\(syllable)'")
            }
            result.append(syllable)
        }
        return result
    }
}

/// The ambiguity table (spec/01-engine.md 8.3, ENG-R821, ENG-R827): `raw  decision  status  display  run
/// viKind  note`.
struct AmbiguityRow: Equatable {
    enum Decision: String { case vi, en }
    enum Status: String { case proposed, reviewed, unreviewed }
    /// ENG-R827: `vi` means rule L10 never restores the word.
    enum Run: String { case en, vi }
    /// ENG-R827: the kind of the Vietnamese reading.
    enum ReadingKind: String { case particle, function, content }

    let raw: String
    let decision: Decision
    let status: Status
    let display: String
    let run: Run
    let viKind: ReadingKind
    let note: String

    init(
        raw: String, decision: Decision, status: Status, display: String, run: Run = .en,
        viKind: ReadingKind = .content, note: String
    ) {
        self.raw = raw
        self.decision = decision
        self.status = status
        self.display = display
        self.run = run
        self.viKind = viKind
        self.note = note
    }

    /// Why `ambiguity-candidates --merge` generated an `en` row (docs/decisions/0202), stored as a token in the
    /// note so that `build` can fail when the reason no longer holds.
    enum GeneratedReason: String, CaseIterable {
        /// English raw keys whose display is not attested: rule L8 restores the word whatever the row says.
        case unattested = "[generated:unattested]"
        /// A tech-always word: rule L11 keeps it as typed without a row.
        case techAlways = "[generated:tech-always]"
    }

    static let header = "raw\tdecision\tstatus\tdisplay\trun\tviKind\tnote"

    /// The generation reason recorded in the note, if any.
    var generatedReason: GeneratedReason? {
        GeneratedReason.allCases.first { note.contains($0.rawValue) }
    }

    var line: String {
        "\(raw)\t\(decision.rawValue)\t\(status.rawValue)\t\(display)\t\(run.rawValue)\t\(viKind.rawValue)\t\(note)"
    }

    static func load(_ url: URL) throws -> [AmbiguityRow] {
        let lines = try FileIO.readUTF8(url).split(separator: "\n", omittingEmptySubsequences: false)
        var rows: [AmbiguityRow] = []
        var seen = Set<String>()
        var sawHeader = false
        for (index, raw) in lines.enumerated() {
            let line = String(raw)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if !sawHeader {
                guard line == header else { throw BuilderError("ambiguity.tsv: first row must be '\(header)'") }
                sawHeader = true
                continue
            }
            let row = try parse(line, number: index + 1)
            guard seen.insert(row.raw).inserted else {
                throw BuilderError("ambiguity.tsv line \(index + 1): duplicate raw '\(row.raw)'")
            }
            rows.append(row)
        }
        return rows
    }

    static func parse(_ line: String, number: Int) throws -> AmbiguityRow {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7 else {
            throw BuilderError("ambiguity.tsv line \(number): expected 7 tab-separated fields")
        }
        guard TechList.isValidEntry(fields[0]) else {
            throw BuilderError("ambiguity.tsv line \(number): raw '\(fields[0])' must be lowercase a-z/0-9")
        }
        guard let decision = Decision(rawValue: fields[1]) else {
            throw BuilderError("ambiguity.tsv line \(number): decision must be vi or en")
        }
        guard let status = Status(rawValue: fields[2]) else {
            throw BuilderError("ambiguity.tsv line \(number): status must be proposed, reviewed or unreviewed")
        }
        guard VietnameseText.isNFC(fields[3]) else {
            throw BuilderError("ambiguity.tsv line \(number): display must be NFC")
        }
        guard let run = Run(rawValue: fields[4]) else {
            throw BuilderError("ambiguity.tsv line \(number): run must be en or vi")
        }
        guard let viKind = ReadingKind(rawValue: fields[5]) else {
            throw BuilderError("ambiguity.tsv line \(number): viKind must be particle, function or content")
        }
        return AmbiguityRow(
            raw: fields[0], decision: decision, status: status, display: fields[3], run: run, viKind: viKind,
            note: fields[6])
    }
}
