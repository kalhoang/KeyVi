// SPDX-License-Identifier: MPL-2.0
//
// RV5 of ENG-R828 (ENG-R850 as amended on 16/11/2026, REG-36) with the bundled data. The product owner typed a
// Vietnamese sentence in iTerm2 (compat rule `terminal.default`: the code context, `lookaheadRevision` off,
// PLT-R357): `Tar thuwr cais nayf` gave `Tar thử cái này`, because at the start of a line nothing stands before
// `tar`, so rule L9 restored it and no later rule looked at it again. RV5 gives such a word its Vietnamese
// display once the next word shows the line is Vietnamese text; shell lines keep their keys. The product owner then
// ruled (16/11/2026, ENG-R850) that a capital first letter at a line start is itself a sign of a Vietnamese sentence:
// a word in sentence case committed by a space is decided at its own commit, except the capitalized code words
// (`host`, for `Host github.com` in ~/.ssh/config), which keep L9 and RV5 with its strict evidence.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("RV5 (ENG-R828, ENG-R850, REG-36) with the bundled data")
struct LineStartRevisionRealDataTests {
    /// The shipped terminal configuration (PLT-R357), and the code context with every collision rule on.
    static let configurations = [
        EngineConfiguration(appContext: .code, lookaheadRevision: false), EngineConfiguration(appContext: .code),
    ]

    static func driver(_ keys: String, _ configuration: EngineConfiguration) throws -> EngineDriver {
        var driver = EngineDriver(configuration: configuration, resources: try RealData.resources())
        try driver.send(KeyNotation.events(keys))
        return driver
    }

    /// D29 off in the terminal configuration (`lineStartRevision`, ENG-R829).
    static let d29Off = EngineConfiguration(appContext: .code, lookaheadRevision: false, lineStartRevision: false)

    @Test("REG-36: the product owner's sentence in iTerm2 gives Tả thử cái này, decided at the first word's commit")
    func productOwnerSentence() throws {
        for configuration in Self.configurations + [Self.d29Off] {
            let driver = try Self.driver("Tar thuwr cais nayf\n", configuration)
            #expect(driver.field.string == "Tả thử cái này\n")
            #expect(driver.outputs.compactMap(\.revision).isEmpty)
            #expect(driver.outputs.first { $0.decision != nil }?.decision?.restores == false)
        }
        // Typed in lowercase, RV5 revises the first word once the next one is Vietnamese; with D29 off it stays.
        for configuration in Self.configurations {
            let driver = try Self.driver("tar thuwr cais nayf\n", configuration)
            #expect(driver.field.string == "tả thử cái này\n")
            #expect(driver.outputs.compactMap(\.revision) == [.lineVietnamese])
        }
        #expect(try Self.driver("tar thuwr cais nayf\n", Self.d29Off).field.string == "tar thử cái này\n")
    }

    @Test("Every code-only word that rule L9 reaches is revised at a line start before a Vietnamese word")
    func everyReachableWord() throws {
        let resources = try RealData.resources()
        var revised: [String] = []
        for word in try RealData.codeOnlyWords() {
            var driver = EngineDriver(configuration: Self.configurations[0], resources: resources)
            try driver.type(word + " ")
            guard driver.outputs.last?.decision == .restored(.codeContext) else { continue }
            try driver.type("thuwr ")
            if driver.outputs.last?.revision == .lineVietnamese { revised.append(word) }
        }
        print("[ENG-R850] code-only words that RV5 revises at a line start with the bundled data (Telex): \(revised)")
        #expect(revised == ["host", "tar", "tee"])
    }

    @Test(
        "Shell lines keep their commands as typed",
        arguments: [
            ("tar -xzf a.tgz\n", "tar -xzf a.tgz\n"),
            ("tar xf banr.tar\n", "tar xf bản.tar\n"),
            ("tee nhaatj-kys.log\n", "tee nhật-ký.log\n"),
            ("tee nhaatj.log\n", "tee nhật.log\n"),
            ("sudo tar thuwr\n", "sudo tar thử\n"),
            ("host google.com\n", "host google.com\n"),
            ("host minh\n", "host minh\n"),
            ("host anh 8.8.8.8\n", "host anh 8.8.8.8\n"),
            ("dungf `tar` thuwr\n", "dùng `tar` thử\n"),
            ("`tar thuwr\n", "`tar thử\n"),
            // A one-word line: Return ends the line before the next word is typed.
            ("tar\nthuwr\n", "tar\nthử\n"),
            // Tab completes a file name in a shell, so it never confirms Vietnamese text.
            ("tar thuwr\t", "tar thử\t"),
        ])
    func shellLines(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            let driver = try Self.driver(keys, configuration)
            #expect(driver.field.string == expected, "\(keys.debugDescription)")
            #expect(!driver.outputs.contains { $0.revision == .lineVietnamese }, "\(keys.debugDescription)")
        }
    }

    @Test(
        "A word in sentence case at a line start, committed by a space, starts a sentence (ENG-R850)",
        arguments: [
            ("Tee tay quas\n", "Tê tay quá\n"),
            ("Tar anh aasy\n", "Tả anh ấy\n"),
            ("Tar thuwr.\n", "Tả thử.\n"),
            ("Tar em ddi\n", "Tả em đi\n"),
            ("Tar \n", "Tả \n"),
            // The cost (ENG-R850): an English line or a command typed with a capital reads as a sentence.
            ("Tar archives are\n", "Tả archives are\n"),
            ("Tee nhaatj.log\n", "Tê nhật.log\n"),
        ])
    func sentenceCase(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations + [Self.d29Off] {
            let driver = try Self.driver(keys, configuration)
            #expect(driver.field.string == expected, "\(keys.debugDescription)")
            #expect(driver.outputs.compactMap(\.revision).isEmpty, "\(keys.debugDescription)")
            #expect(!driver.outputs.contains { $0.decision == .restored(.codeContext) }, "\(keys.debugDescription)")
        }
    }

    @Test(
        "`Host` is a capitalized code word: L9 restores it in sentence case too, and RV5 keeps its strict evidence",
        arguments: [
            ("Host minh\n", "Host minh\n", false),
            ("Host github.com\n", "Host github.com\n", false),
            ("Host: example.com\n", "Host: example.com\n", false),
            ("Host anh 8.8.8.8\n", "Host anh 8.8.8.8\n", false),
            ("Host nayf\n", "Hót này\n", true),
            ("Host mowis chayj nhanh\n", "Hót mới chạy nhanh\n", true),
        ])
    func capitalizedHost(_ keys: String, _ expected: String, _ revises: Bool) throws {
        for configuration in Self.configurations {
            let driver = try Self.driver(keys, configuration)
            #expect(driver.field.string == expected, "\(keys.debugDescription)")
            #expect(driver.outputs.contains { $0.decision == .restored(.codeContext) }, "\(keys.debugDescription)")
            #expect(driver.outputs.contains { $0.revision == .lineVietnamese } == revises, "\(keys.debugDescription)")
        }
    }

    @Test(
        "Known costs of RV5 (ENG-R850): lowercase before an unchanged syllable or a period, punctuation after t",
        arguments: [
            ("tar anh aasy\n", "tar anh ấy\n"),
            ("tee tay quas\n", "tee tay quá\n"),
            ("tar thuwr.\n", "tar thử.\n"),
            ("Tar: thuwr\n", "Tar: thử\n"),
            ("Tar\nthuwr\n", "Tar\nthử\n"),
            // `em` is also English (the unit), so it is not RV4's evidence of a syllable typed unchanged.
            ("tar em ddi\n", "tar em đi\n"),
        ])
    func knownCosts(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            let driver = try Self.driver(keys, configuration)
            #expect(driver.field.string == expected, "\(keys.debugDescription)")
            #expect(!driver.outputs.contains { $0.revision == .lineVietnamese }, "\(keys.debugDescription)")
        }
    }

    @Test("After Return the line starts again; an English command line keeps the next line's word English (L10)")
    func afterACommandLine() throws {
        for configuration in Self.configurations {
            #expect(try Self.driver("ls -la\ntar thuwr\n", configuration).field.string == "ls -la\ntả thử\n")
            #expect(try Self.driver("ls -la\nTar thuwr\n", configuration).field.string == "ls -la\nTả thử\n")
            // The run's window survives Return (ENG-R823): after an English line the general context's rules
            // restore `tar` by L10, so RV5 leaves it, and so does the sentence condition.
            #expect(
                try Self.driver("check the logs\ntar thuwr\n", configuration).field.string
                    == "check the logs\ntar thử\n")
            #expect(
                try Self.driver("check the logs\nTar thuwr\n", configuration).field.string
                    == "check the logs\nTar thử\n")
        }
    }

    @Test("ENG-R829: Escape right after the revision gives the keys back and a strong English signal")
    func undo() throws {
        var driver = try Self.driver("tar thuwr ", EngineConfiguration(appContext: .code))
        let output = try driver.send(.restoreToggle)
        #expect(driver.field.string == "tar thử ")
        #expect(
            output.collisionSignals == [
                CollisionSignal(word: "tar", context: .sentenceStart, side: .english, strength: .strong)
            ])
    }

    // MARK: - 13.9.4

    struct Row: Sendable, CustomStringConvertible {
        let id: String
        let keys: String
        let text: String
        let decided: String
        var description: String { id }
    }

    /// The rows of 13.9.4, read from the spec in the repository.
    static let rows: [Row] = {
        let url = TestPaths.repoRoot.appendingPathComponent("spec/01-engine.md")
        guard let spec = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inSection = false
        var rows: [Row] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { inSection = line.hasPrefix("#### 13.9.4") }
            guard inSection, line.hasPrefix("| K") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 4 else { continue }
            func unquote(_ cell: String) -> String { cell.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            rows.append(Row(id: cells[0], keys: unquote(cells[1]), text: unquote(cells[2]), decided: cells[3]))
        }
        return rows
    }()

    @Test("13.9.4 has its 20 rows")
    func tableIsComplete() {
        #expect(Self.rows.map(\.id) == (1...20).map { String(format: "K%02d", $0) })
    }

    @Test("ENG-R850, ENG-R828: every row of 13.9.4", arguments: rows)
    func row(_ row: Row) throws {
        for configuration in Self.configurations {
            let driver = try Self.driver(row.keys + "\n", configuration)
            #expect(driver.field.string == row.text + "\n", "\(row.id): \(driver.field.string.debugDescription)")
            let decisions = driver.outputs.compactMap(\.decision)
            if row.decided.hasPrefix("L9 restores") {
                #expect(decisions.contains(.restored(.codeContext)), "\(row.id)")
            } else {
                #expect(row.decided.hasPrefix("L9 does not apply"), "\(row.id): the column names L9")
                #expect(!decisions.contains(.restored(.codeContext)) && decisions.first?.restores == false, "\(row.id)")
            }
            let revised = driver.outputs.contains { $0.revision == .lineVietnamese }
            #expect(revised == row.decided.contains("RV5 revises"), "\(row.id)")
        }
        // 13.9.4: with D29 off a row that names RV5 keeps the first word as typed, every other row is the same.
        let off = try Self.driver(row.keys + "\n", Self.d29Off).field.string
        if row.decided.contains("RV5 revises") {
            let first = row.keys.prefix { $0 != " " }
            let rest = row.text.drop { $0 != " " }
            #expect(off == String(first) + String(rest) + "\n", "\(row.id): \(off.debugDescription)")
        } else {
            #expect(off == row.text + "\n", "\(row.id): \(off.debugDescription)")
        }
    }
}
