// SPDX-License-Identifier: MPL-2.0
//
// Reading and validating the resource files written by lexicon-builder (format 1, data/README.md):
// UTF-8, LF line ends, one entry per line, final newline, no blank lines, entries unique.
// manifest.json records size, entry count and SHA-256 of every file; a mismatch is an error so that a
// truncated or hand-edited bundle never loads silently.

import Foundation
import VietnameseEngine

#if canImport(CryptoKit)
import CryptoKit
#endif

/// The generated files and how their entries are validated.
enum ResourceFile: String, CaseIterable {
    case english = "english.txt"
    case techAlways = "tech-always.txt"
    case techCodeOnly = "tech-code-only.txt"
    case attested = "attested.txt"
    case ambiguity = "ambiguity.tsv"
    case notices = "NOTICES.txt"
    // The collision lists (format 2; spec/01-engine.md ENG-R825 to ENG-R828, ENG-R863).
    case phrases = "phrases.txt"
    case collisionSupplement = "collision-supplement.txt"
    case boundaryParticles = "boundary-particles.txt"
    case englishFunctionWords = "english-function-words.txt"
    case englishLean = "english-lean-neutral.txt"
    case tailWords = "vi-tail-words.txt"
    case tailParticles = "vi-tail-particles.txt"
    case preGuard = "english-pre-guard.txt"
}

/// The ambiguity table as the loader returns it (ENG-R821, ENG-R827).
struct AmbiguityTable {
    /// Raw keys -> the decision rule L11 applies (unreviewed rows behave as `vi`).
    var decisions: [String: Language] = [:]
    /// Rows marked `run: vi`.
    var runExempt: [String] = []
    /// Raw keys -> the kind of the Vietnamese reading.
    var readingKinds: [String: VietnameseReadingKind] = [:]
}

struct ResourceManifest: Decodable {
    struct File: Decodable {
        let name: String
        let bytes: Int
        let entries: Int?
        let sha256: String
    }

    let format: Int
    let files: [File]

    /// Format 2 (15/11/2026): the ambiguity table has the `run` and `viKind` columns and the collision lists
    /// ship.
    static let supportedFormat = 2
    static let fileName = "manifest.json"
}

struct ResourceDirectory {
    typealias LoadError = Resources.LoadError

    let directory: URL
    let manifest: [String: ResourceManifest.File]

    init(_ directory: URL) throws {
        self.directory = directory
        let data = try Self.read(
            directory.appendingPathComponent(ResourceManifest.fileName), name: ResourceManifest.fileName)
        let decoded: ResourceManifest
        do {
            decoded = try JSONDecoder().decode(ResourceManifest.self, from: data)
        } catch {
            throw LoadError.malformedResource("\(ResourceManifest.fileName): \(error)")
        }
        guard decoded.format == ResourceManifest.supportedFormat else {
            throw LoadError.malformedResource("\(ResourceManifest.fileName): unsupported format \(decoded.format)")
        }
        manifest = Dictionary(decoded.files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Lists

    /// Entries of a word list, validated per file kind.
    func wordList(_ file: ResourceFile) throws -> [String] {
        let data = try verifiedData(file)
        let words: [String]
        switch file {
        case .english: words = try Self.asciiLines(data, file: file, allowDigits: false)
        case .techAlways, .techCodeOnly: words = try Self.asciiLines(data, file: file, allowDigits: true)
        case .attested, .tailWords, .tailParticles: words = try Self.syllableLines(data, file: file)
        case .collisionSupplement, .boundaryParticles, .englishFunctionWords, .englishLean, .preGuard:
            words = try Self.asciiLines(data, file: file, allowDigits: false)
        case .phrases: words = try Self.phraseLines(data, file: file)
        case .ambiguity, .notices: preconditionFailure("\(file.rawValue) is not a word list")
        }
        try checkEntryCount(words.count, file: file)
        try Self.checkUnique(words, file: file, firstLine: 1)
        return words
    }

    /// Rows `raw  decision  status  display  run  viKind  note` -> the language used by rule L11 (ENG-R821):
    /// `en` and `vi` rows apply as decided when proposed or reviewed; unreviewed rows behave as `vi`. `run: vi`
    /// rows are exempt from rule L10 and `viKind` is the kind of the Vietnamese reading (ENG-R827).
    func ambiguityTable() throws -> AmbiguityTable {
        let file = ResourceFile.ambiguity
        let lines = try Self.utf8Lines(try verifiedData(file), file: file)
        guard lines.first == "raw\tdecision\tstatus\tdisplay\trun\tviKind\tnote" else {
            throw LoadError.malformedEntry(resource: file.rawValue, line: 1, reason: .invalidHeader)
        }
        var result = AmbiguityTable()
        for (index, line) in lines.enumerated().dropFirst() {
            let number = index + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7 else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .wrongFieldCount)
            }
            let raw = String(fields[0])
            guard Self.isTechEntry(raw.utf8) else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .invalidCharacter)
            }
            var decision: Language
            switch fields[1] {
            case "vi": decision = .vietnamese
            case "en": decision = .english
            default: throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .invalidDecision)
            }
            switch fields[2] {
            case "proposed", "reviewed": break
            case "unreviewed": decision = .vietnamese
            default: throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .invalidStatus)
            }
            switch fields[4] {
            case "en": break
            case "vi": result.runExempt.append(raw)
            default: throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .invalidRun)
            }
            switch fields[5] {
            case "particle": result.readingKinds[raw] = .particle
            case "function": result.readingKinds[raw] = .function
            case "content": break
            default: throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .invalidReadingKind)
            }
            guard result.decisions.updateValue(decision, forKey: raw) == nil else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: number, reason: .duplicate)
            }
        }
        try checkEntryCount(result.decisions.count, file: file)
        return result
    }

    func notices() throws -> String {
        let data = try verifiedData(.notices)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.malformedResource("\(ResourceFile.notices.rawValue): not UTF-8")
        }
        return text
    }

    // MARK: Integrity

    private func verifiedData(_ file: ResourceFile) throws -> Data {
        guard let expected = manifest[file.rawValue] else {
            throw LoadError.malformedResource("\(ResourceManifest.fileName) has no entry for \(file.rawValue)")
        }
        let data = try Self.read(directory.appendingPathComponent(file.rawValue), name: file.rawValue)
        guard data.count == expected.bytes else {
            throw LoadError.integrityMismatch(
                resource: file.rawValue, detail: "\(data.count) bytes, expected \(expected.bytes)")
        }
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
        guard digest == expected.sha256 else {
            throw LoadError.integrityMismatch(
                resource: file.rawValue, detail: "SHA-256 \(digest), expected \(expected.sha256)")
        }
        #endif
        return data
    }

    private func checkEntryCount(_ count: Int, file: ResourceFile) throws {
        if let expected = manifest[file.rawValue]?.entries, expected != count {
            throw LoadError.integrityMismatch(resource: file.rawValue, detail: "\(count) entries, expected \(expected)")
        }
    }

    private static func read(_ url: URL, name: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missingResource(name) }
        do { return try Data(contentsOf: url) } catch { throw LoadError.malformedResource("\(name): unreadable") }
    }

    // MARK: Line parsing

    /// ASCII lists: `a-z` (plus `0-9` with at least one letter for the tech lists). Parsed on raw bytes
    /// so the 40,000-word English list loads well inside the ENG-R1231 budget.
    private static func asciiLines(_ data: Data, file: ResourceFile, allowDigits: Bool) throws -> [String] {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [String] in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var words: [String] = []
            words.reserveCapacity(bytes.count / 8)
            var start = 0
            var line = 1
            while start < bytes.count {
                var end = start
                var hasLetter = false
                while end < bytes.count, bytes[end] != 0x0A {
                    let byte = bytes[end]
                    if byte >= 0x61 && byte <= 0x7A {
                        hasLetter = true
                    } else if !(allowDigits && byte >= 0x30 && byte <= 0x39) {
                        throw LoadError.malformedEntry(resource: file.rawValue, line: line, reason: .invalidCharacter)
                    }
                    end += 1
                }
                guard end < bytes.count else {
                    throw LoadError.malformedEntry(resource: file.rawValue, line: line, reason: .missingFinalNewline)
                }
                guard end > start else {
                    throw LoadError.malformedEntry(resource: file.rawValue, line: line, reason: .emptyLine)
                }
                guard hasLetter else {
                    throw LoadError.malformedEntry(resource: file.rawValue, line: line, reason: .invalidCharacter)
                }
                words.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
                start = end + 1
                line += 1
            }
            return words
        }
    }

    /// Phrases (ENG-R826): 2 to 4 lowercase words a-z separated by one space.
    private static func phraseLines(_ data: Data, file: ResourceFile) throws -> [String] {
        let lines = try utf8Lines(data, file: file)
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: index + 1, reason: .emptyLine)
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            guard (2...4).contains(words.count),
                words.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A } })
            else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: index + 1, reason: .invalidCharacter)
            }
        }
        return lines
    }

    /// Attested syllables: lowercase NFC strings of Vietnamese letters (spec/01-engine.md 3.2).
    private static func syllableLines(_ data: Data, file: ResourceFile) throws -> [String] {
        let lines = try utf8Lines(data, file: file)
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: index + 1, reason: .emptyLine)
            }
            guard line.unicodeScalars.elementsEqual(line.precomposedStringWithCanonicalMapping.unicodeScalars) else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: index + 1, reason: .notNormalized)
            }
            guard line.allSatisfy(VietnameseLetters.isLowercaseLetter) else {
                throw LoadError.malformedEntry(resource: file.rawValue, line: index + 1, reason: .invalidCharacter)
            }
        }
        return lines
    }

    /// Splits a UTF-8 file into lines; requires a final newline. Empty file -> no lines.
    private static func utf8Lines(_ data: Data, file: ResourceFile) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.malformedResource("\(file.rawValue): not UTF-8")
        }
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.last == "" else {
            throw LoadError.malformedEntry(resource: file.rawValue, line: lines.count, reason: .missingFinalNewline)
        }
        lines.removeLast()
        return lines
    }

    private static func checkUnique(_ words: [String], file: ResourceFile, firstLine: Int) throws {
        // lexicon-builder writes every list sorted by UTF-8 bytes, so strictly ascending neighbours prove
        // uniqueness without hashing (ENG-R1231). For NFC text String `<` follows code point order, which is
        // UTF-8 byte order. Any other order falls back to the set below.
        var ascending = true
        var index = 1
        while ascending, index < words.count {
            ascending = words[index - 1] < words[index]
            index += 1
        }
        if ascending { return }
        var seen = Set<String>(minimumCapacity: words.count)
        for (index, word) in words.enumerated() where !seen.insert(word).inserted {
            throw LoadError.malformedEntry(resource: file.rawValue, line: index + firstLine, reason: .duplicate)
        }
    }

    private static func isTechEntry(_ bytes: String.UTF8View) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
            && bytes.contains { $0 >= 0x61 && $0 <= 0x7A }
    }
}

/// Lowercase letters allowed in attested syllables: the 12 vowel letters with any of the six tones,
/// the Tier A consonants and `z` (spec/01-engine.md 3.2, 3.3).
enum VietnameseLetters {
    static let letters: Set<Character> = {
        var set: Set<Character> = [
            "b", "c", "d", "đ", "g", "h", "k", "l", "m", "n", "p", "q", "r", "s", "t", "v", "x", "z",
        ]
        let marks = ["\u{0301}", "\u{0300}", "\u{0309}", "\u{0303}", "\u{0323}"]
        for vowel in ["a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y"] {
            set.insert(Character(vowel))
            for mark in marks { set.insert(Character((vowel + mark).precomposedStringWithCanonicalMapping)) }
        }
        return set
    }()

    static func isLowercaseLetter(_ character: Character) -> Bool { letters.contains(character) }
}
