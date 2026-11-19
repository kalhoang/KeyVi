// SPDX-License-Identifier: MPL-2.0
//
// spec/01-engine.md 13.12 (rows S01 to S84, ENG-T50) with the bundled data. The rows live in
// Tests/VietnameseEngineTests/Corpus/typo-corrections.tsv; `tableMatchesTheSpec` keeps their ids and texts equal to the
// spec's table. With the switch off every row gives the text the 1.0 rules leave (ENG-R1119: as if section 11A were
// absent), checked against the current engine. With the switch on every row gives the spec's text, decision and
// signal: that test is enabled by the logic track once the correction exists (plan of 19/11/2026, Task 19). Rows S23,
// S24 and S26 depend on the open questions Q10 and Q11 of spec section 15: `CorrectionPolicy` decides which of their
// two texts applies, and `theSpecRowsFollowThePolicy` keeps the spec in step with it.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("13.12 typo correction with the bundled data")
struct TypoCorrectionExampleTests {
    struct Row: Sendable, CustomStringConvertible {
        let id: String
        let method: String
        let setup: String
        let keys: String
        let expected: String
        let expectedOff: String
        let decision: String
        let signal: String
        let note: String
        var description: String { id }

        /// The field under the other answer to Q10 or Q11 (`q10:` or `q11:` note), nil for the other rows.
        var alternative: (question: String, text: String)? {
            for question in ["q10", "q11"] where note.hasPrefix(question + ":") {
                return (question, String(note.dropFirst(question.count + 1)))
            }
            return nil
        }

        /// The text expected with the switch on under the answers `CorrectionPolicy` holds.
        var expectedUnderThePolicy: String {
            guard let alternative else { return expected }
            let recommended =
                alternative.question == "q10"
                ? CorrectionPolicy.sentenceStart == .corrected : CorrectionPolicy.commitKeys == .everyCommitKey
            return recommended ? expected : alternative.text
        }
    }

    struct SpecRow: Sendable {
        let id: String
        let keys: String
        let text: String
    }

    static let fixtureURL = TestPaths.packageRoot.appendingPathComponent(
        "Tests/VietnameseEngineTests/Corpus/typo-corrections.tsv")

    /// The fixture rows, in file order; empty when the file does not parse (`fixtureParses` reports why).
    static let rows: [Row] = (try? loadRows()) ?? []

    /// The rows the switch-off test types on their own: an `after:` row continues another one.
    static let standaloneRows: [Row] = rows.filter { !$0.setup.hasPrefix("after:") }

    static func loadRows() throws -> [Row] {
        let table = try TSVTable(name: "typo-corrections.tsv", text: String(contentsOf: fixtureURL, encoding: .utf8))
        return table.rows.map { row in
            Row(
                id: row["id"], method: row["method"], setup: row["setup"], keys: row["keys"],
                expected: row["expected"], expectedOff: row["expected_off"], decision: row["decision"],
                signal: row["signal"], note: row["note"])
        }
    }

    /// The `| S..` rows of 13.12, read from the spec in the repository.
    static let specRows: [SpecRow] = {
        let url = TestPaths.repoRoot.appendingPathComponent("spec/01-engine.md")
        guard let spec = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inSection = false
        var rows: [SpecRow] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { inSection = line.hasPrefix("### 13.12") }
            guard inSection, line.hasPrefix("| S") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 4 else { continue }
            rows.append(SpecRow(id: cells[0], keys: cells[1], text: cells[2]))
        }
        return rows
    }()

    /// The field a cell of the spec's text column names: its first backticked text, then a Return when the cell
    /// says so (S26).
    static func fieldText(_ cell: String) -> String {
        let quoted = firstBackticked(cell) ?? cell
        return cell.contains("and the Return") ? quoted + "\n" : quoted
    }

    static func firstBackticked(_ cell: String) -> String? {
        let parts = cell.split(separator: "`", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    // MARK: The table

    @Test("The fixture parses and has the 84 rows of 13.12 in the spec's order, with the spec's text")
    func tableMatchesTheSpec() throws {
        _ = try Self.loadRows()
        #expect(Self.rows.count == 84)
        #expect(Self.specRows.map(\.id) == (1...84).map { String(format: "S%02d", $0) })
        #expect(Self.rows.map(\.id) == Self.specRows.map(\.id))
        for (row, spec) in zip(Self.rows, Self.specRows) {
            #expect(row.expected == Self.fieldText(spec.text), "\(row.id): \(spec.text)")
            // The keys the spec names are the keys the row types (the spec adds the committing key in words).
            if let keys = Self.firstBackticked(spec.keys) { #expect(row.keys.contains(keys), "\(row.id): \(keys)") }
            #expect(["Telex", "VNI"].contains(row.method), "\(row.id)")
            #expect(row.decision != "?" && !row.decision.isEmpty, "\(row.id): decision not filled")
            #expect(row.decision == "-" || Self.decision(row.decision) != nil, "\(row.id): \(row.decision)")
            #expect(row.signal == "-" || Self.signal(row.signal) != nil, "\(row.id): \(row.signal)")
        }
        // Only S23 and S24 depend on Q10 and only S26 on Q11; each alternative differs from the recommendation.
        #expect(Self.rows.filter { $0.alternative?.question == "q10" }.map(\.id) == ["S23", "S24"])
        #expect(Self.rows.filter { $0.alternative?.question == "q11" }.map(\.id) == ["S26"])
        for row in Self.rows { if let alternative = row.alternative { #expect(alternative.text != row.expected) } }
    }

    @Test("Q10 and Q11: rows S23, S24 and S26 of the spec follow CorrectionPolicy")
    func theSpecRowsFollowThePolicy() throws {
        func text(_ id: String) throws -> String {
            Self.fieldText(try #require(Self.specRows.first { $0.id == id }).text)
        }
        let q10Corrected = CorrectionPolicy.sentenceStart == .corrected
        #expect((try text("S23") == "Android ") == q10Corrected)
        #expect((try text("S24") == "xong. Receive ") == q10Corrected)
        #expect((try text("S26") == "android\n") == (CorrectionPolicy.commitKeys == .everyCommitKey))
    }

    // MARK: The switch off (the 1.0 side of every row)

    @Test("ENG-R1119: with the switch off each row gives what the 1.0 rules leave", arguments: standaloneRows)
    func rowsWithTheSwitchOffMatchThe1_0Engine(_ row: Row) throws {
        let driver = try Self.type(row, typoCorrection: false)
        #expect(driver.field.string == row.expectedOff, "\(row.id): \(driver.field.string.debugDescription)")
        for output in driver.outputs {
            if case .corrected? = output.decision { Issue.record("\(row.id): a correction with the switch off") }
            if case .neverCorrect? = output.learning { Issue.record("\(row.id): a neverCorrect with the switch off") }
        }
        let decision = driver.outputs.compactMap(\.decision).last
        guard let expected = Self.decision(row.decision) else { return }
        if case .corrected(let rule) = expected {
            // ENG-R1110 (b), ENG-R1115: a corrected token is one the 8.1 decision leaves as typed (L0, or a restore
            // by any rule but L1 and L2), or the cluster case kept by L6; the correction names that rule.
            #expect(decision?.rule == rule, "\(row.id): \(String(describing: decision))")
            #expect(decision.map(Self.leavesTheTypedWordOrIsTheClusterCase) == true, "\(row.id)")
        } else {
            #expect(decision == expected, "\(row.id): \(String(describing: decision))")
        }
    }

    static func leavesTheTypedWordOrIsTheClusterCase(_ decision: CommitDecision) -> Bool {
        switch decision {
        case .kept(.unchanged), .kept(.extendedSpelling): true
        case .restored(let rule): rule != .userChoice && rule != .userList
        default: false
        }
    }

    // MARK: The switch on (ENG-T50)

    @Test(
        "ENG-T50: with the switch on each row gives the spec's text, decision and signal",
        .disabled("E2 Task 19 enables it once the correction exists"), arguments: rows)
    func rowsWithTheSwitchOn(_ row: Row) throws {
        var field = ""
        var outputs: [EngineOutput] = []
        var neverCorrect: [String] = []
        if row.setup.hasPrefix("after:") {
            let id = String(row.setup.dropFirst("after:".count))
            let first = try #require(Self.rows.first { $0.id == id }, "\(row.id): no row \(id)")
            let before = try Self.type(first, typoCorrection: true)
            field = before.field.string
            outputs = before.outputs
            if case .neverCorrect(let raw)? = Self.signal(first.signal) { neverCorrect = [raw] }
        }
        let driver = try Self.type(row, typoCorrection: true, neverCorrect: neverCorrect)
        field += driver.field.string
        outputs += driver.outputs
        #expect(field == row.expectedUnderThePolicy, "\(row.id): \(field.debugDescription)")
        if row.alternative == nil || row.expectedUnderThePolicy == row.expected,
            let expected = Self.decision(row.decision)
        {
            #expect(driver.outputs.compactMap(\.decision).last == expected, "\(row.id)")
        }
        let signals = outputs.compactMap(\.learning)
        if let signal = Self.signal(row.signal) {
            #expect(signals.contains(signal), "\(row.id): \(signals)")
        } else {
            #expect(!signals.contains { if case .neverCorrect = $0 { true } else { false } }, "\(row.id): \(signals)")
        }
    }

    // MARK: Running a row

    /// Types the row's keys from an empty field with the bundled data and the row's setup.
    static func type(_ row: Row, typoCorrection: Bool, neverCorrect: [String] = []) throws -> EngineDriver {
        var resources = try RealData.resources()
        var never = neverCorrect
        let (kind, value) = setup(row.setup)
        switch kind {
        case "never": never.append(value)
        case "keep": resources.userKeepRaw = WordSet([value])
        case "macro":
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            resources.macros = try MacroTable([MacroTable.Entry(trigger: parts[0], expansion: parts[1])])
        default: break
        }
        resources.userNeverCorrect = WordSet(never)
        let configuration = EngineConfiguration(
            inputMethod: row.method == "VNI" ? .vni : .telex(TelexOptions()),
            appContext: row.setup == "code" ? .code : .general,
            typoCorrection: typoCorrection && row.setup != "off")
        var driver = EngineDriver(configuration: configuration, resources: resources)
        try driver.send(KeyNotation.events(row.keys))
        return driver
    }

    /// `kind:value` of a setup cell (`never:androdi`), or the cell and an empty value.
    static func setup(_ cell: String) -> (String, String) {
        guard let colon = cell.firstIndex(of: ":") else { return (cell, "") }
        return (String(cell[..<colon]), String(cell[cell.index(after: colon)...]))
    }

    /// Every rule of 8.1, by its case name.
    static let rules: [String: CommitRule] = Dictionary(
        uniqueKeysWithValues: [
            CommitRule.unchanged, .userChoice, .userList, .abbreviation, .camelCase, .escape, .toneRemoval, .invalid,
            .extendedSpelling, .notEnglish, .notAttested, .codeContext, .boundaryParticle, .phrase, .learned,
            .englishRun, .ambiguityTable, .techList, .defaultVietnamese,
        ].map { (String(describing: $0), $0) })

    /// `corrected(<rule>)`, `kept(<rule>)`, `restored(<rule>)` or `macro`; nil for `-` or anything else.
    static func decision(_ cell: String) -> CommitDecision? {
        if cell == "macro" { return .macro }
        guard let open = cell.firstIndex(of: "("), cell.hasSuffix(")"),
            let rule = rules[String(cell[cell.index(after: open)..<cell.index(before: cell.endIndex)])]
        else { return nil }
        switch cell[..<open] {
        case "corrected": return .corrected(rule)
        case "kept": return .kept(rule)
        case "restored": return .restored(rule)
        default: return nil
        }
    }

    /// `neverCorrect(<word>)`; nil for `-` or anything else.
    static func signal(_ cell: String) -> LearningSignal? {
        guard cell.hasPrefix("neverCorrect("), cell.hasSuffix(")") else { return nil }
        return .neverCorrect(raw: String(cell.dropFirst("neverCorrect(".count).dropLast()))
    }
}
