// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Section 11: macro table validation (ENG-R1101, ENG-R1103).
@Suite("Macros: table validation (11)")
struct MacroValidationTests {
    typealias Entry = MacroTable.Entry
    typealias Failure = MacroTable.ValidationError

    private func error(_ entries: [Entry]) -> Failure? {
        do {
            _ = try MacroTable(entries)
            return nil
        } catch let error as Failure {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test func validTables() throws {
        _ = try MacroTable([])
        _ = try MacroTable([
            Entry(trigger: "vn", expansion: "Việt Nam"), Entry(trigger: "@@", expansion: "kal@example.com"),
            Entry(trigger: "k1", expansion: "khu 1"), Entry(trigger: "ad.", expansion: "địa chỉ"),
            Entry(trigger: String(repeating: "x", count: 32), expansion: "32"),
            Entry(trigger: "sig", expansion: String(repeating: "ạ", count: 4_000)),
            Entry(trigger: "nl", expansion: "dòng 1\ndòng 2"), Entry(trigger: "del", expansion: ""),
            // Digits are token keys in VNI, so `k` does not shadow `k1x` (only punctuation does).
            Entry(trigger: "k", expansion: "không"), Entry(trigger: "k1x", expansion: "?"),
            // A longer trigger that continues with a letter is reachable.
            Entry(trigger: "vnm", expansion: "Việt Nam!"),
        ])
    }

    @Test func triggerCharacters() {
        #expect(error([Entry(trigger: "", expansion: "x")]) == .emptyTrigger(""))
        #expect(error([Entry(trigger: "v n", expansion: "x")]) == .invalidTriggerCharacter("v n"))
        #expect(error([Entry(trigger: "vn\t", expansion: "x")]) == .invalidTriggerCharacter("vn\t"))
        #expect(error([Entry(trigger: "đc", expansion: "x")]) == .invalidTriggerCharacter("đc"))  // Q6: ASCII only
        #expect(error([Entry(trigger: "é", expansion: "x")]) == .invalidTriggerCharacter("é"))
        let long = String(repeating: "a", count: 33)
        #expect(error([Entry(trigger: long, expansion: "x")]) == .triggerTooLong(long))
    }

    @Test func expansionLength() {
        let expansion = String(repeating: "ạ", count: 4_001)
        #expect(error([Entry(trigger: "x", expansion: expansion)]) == .expansionTooLong("x"))
    }

    @Test func duplicatesIgnoreCase() {
        let entries = [Entry(trigger: "vn", expansion: "Việt Nam"), Entry(trigger: "VN", expansion: "VN")]
        #expect(error(entries) == .duplicateTrigger("VN"))
    }

    @Test func shadowedByShorterTrigger() {
        // ENG-R1103: `ad` fires at the `.` of `ad.`, so `ad.` can never fire; the same for `ad.x`.
        #expect(
            error([Entry(trigger: "ad.", expansion: "1"), Entry(trigger: "ad", expansion: "2")])
                == .shadowedByShorterTrigger(trigger: "ad.", shorter: "ad"))
        #expect(
            error([Entry(trigger: "AD", expansion: "2"), Entry(trigger: "ad.x", expansion: "1")])
                == .shadowedByShorterTrigger(trigger: "ad.x", shorter: "AD"))
        #expect(
            error([Entry(trigger: "@", expansion: "1"), Entry(trigger: "@@", expansion: "2")])
                == .shadowedByShorterTrigger(trigger: "@@", shorter: "@"))
    }

    @Test func firstProblemInEntryOrder() {
        let entries = [
            Entry(trigger: "ok", expansion: "x"), Entry(trigger: "a b", expansion: "x"), Entry(trigger: "", expansion: "x"),
        ]
        #expect(error(entries) == .invalidTriggerCharacter("a b"))
    }

    @Test func tenThousandEntries() throws {
        // ENG-R1105: hash lookup; a 10,000-entry table builds and matches like a small one.
        var entries: [Entry] = []
        for index in 0..<10_000 { entries.append(Entry(trigger: "m\(index)", expansion: "macro \(index)")) }
        entries.append(Entry(trigger: "vn", expansion: "Việt Nam"))
        let table = try MacroTable(entries)
        let resources = SpecFixtures.commitResources(macros: table)
        #expect(try Committing.text("vn m9999 ", resources: resources) == "Việt Nam macro 9999 ")
    }
}

/// Section 11: matching, expansion, casing and history (ENG-R1102 to ENG-R1104).
@Suite("Macros: expansion (11)")
struct MacroExpansionTests {
    static let table: MacroTable = {
        do {
            return try MacroTable([
                .init(trigger: "vn", expansion: "Việt Nam"), .init(trigger: "@@", expansion: "kal@example.com"),
                .init(trigger: "dc", expansion: "được"), .init(trigger: "k1", expansion: "khu 1"),
                .init(trigger: "ad.", expansion: "địa chỉ"), .init(trigger: "ttt", expansion: "Thân thiện", adaptCase: false),
                .init(trigger: "hcm", expansion: "Hồ Chí Minh"), .init(trigger: "sig", expansion: "Trân trọng,\nKal"),
                .init(trigger: "zz", expansion: ""), .init(trigger: "ddc", expansion: "đặc"),
                .init(trigger: "smile", expansion: "\u{1F600}"), .init(trigger: "1st", expansion: "first"),
            ])
        } catch {
            Issue.record("macro table: \(error)")
            return .empty
        }
    }()

    static let resources = SpecFixtures.commitResources(macros: table)

    private func text(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws -> String {
        try Committing.text(keys, configuration, resources: Self.resources)
    }

    @Test func examplesOfSection11() throws {
        let driver = try Committing.driver("vn ", resources: Self.resources)
        #expect(driver.field.string == "Việt Nam ")
        #expect(driver.outputs.last?.decision == .macro)
        #expect(
            driver.outputs.last?.action
                == .edit(TextEdit(deleteCount: 2, deleteUTF16Count: 2, insert: "Việt Nam"), thenPassThrough: true))
        #expect(try text("Vn ") == "Việt Nam ")
        #expect(try text("VN ") == "VIỆT NAM ")
        #expect(try text("vn.") == "Việt Nam.")
        #expect(try text("@@\n") == "kal@example.com\n")
        #expect(try text("dc ") == "được ")
        #expect(try text("vnd ") == "vnd ")
    }

    @Test func spanIncludesPunctuationAndDigits() throws {
        // ENG-R1102: boundary characters typed since the last whitespace are part of the span.
        #expect(try text("ad. ") == "địa chỉ ")
        #expect(try text("k1 ") == "khu 1 ")  // Telex: `1` is a boundary
        #expect(try text("k1 ", EngineConfiguration(inputMethod: .vni)) == "khu 1 ")  // VNI: `1` is a key
        #expect(try text("@@,") == "kal@example.com,")
        #expect(try text("x ad. ") == "x địa chỉ ")
        // The terminator is the first boundary after a complete trigger.
        #expect(try text("vn,dc ") == "Việt Nam,dc ")
    }

    @Test func noPartialOrLongerMatches() throws {
        #expect(try text("hc ") == "hc ")
        #expect(try text("hcmc ") == "hcmc ")
        #expect(try text("xvn ") == "xvn ")
        #expect(try text("hcm ") == "Hồ Chí Minh ")
        // The span starts after whitespace, Return, Tab or a reset.
        #expect(try text("x\tvn ") == "x\tViệt Nam ")
        #expect(try text("v⟲n ") == "vn ")
    }

    @Test func spanOfMoreThan32CharactersIsNotLookedUp() throws {
        let trigger = String(repeating: "q", count: 32)
        let table = try MacroTable([.init(trigger: trigger, expansion: "!"), .init(trigger: "x" + trigger.dropFirst(), expansion: "?")])
        let resources = SpecFixtures.commitResources(macros: table)
        #expect(try Committing.text(trigger + " ", resources: resources) == "! ")
        #expect(try Committing.text("." + trigger + " ", resources: resources) == "." + trigger + " ")
    }

    @Test func caseAdaptation() throws {
        #expect(try text("Dc ") == "Được ")
        #expect(try text("DC ") == "ĐƯỢC ")
        #expect(try text("dC ") == "được ")
        #expect(try text("TTT ") == "Thân thiện ")  // adaptCase: false
        #expect(try text("ttt ") == "Thân thiện ")
        #expect(try text("1ST ") == "FIRST ")
        #expect(MacroCase.capitalisingFirstLetter("(xin chào)") == "(Xin chào)")
        #expect(MacroCase.capitalisingFirstLetter("1st") == "1st")
        // A trigger with no letters is never case-adapted.
        #expect(MacroCase.adapt("abc", toTyped: Array("@@".utf8), adaptCase: true) == "abc")
        // A single capital letter capitalises the first letter only.
        #expect(MacroCase.adapt("xin chào", toTyped: Array("X".utf8), adaptCase: true) == "Xin chào")
    }

    @Test func expansionIsOneLiteralHistoryToken() throws {
        // ENG-R1104.
        var driver = try Committing.driver("ban vn ", resources: Self.resources)
        #expect(driver.state.historyCount == 2)
        try driver.send(.backspace)
        #expect(driver.state.activeDisplay == "Việt Nam" && driver.state.activeRawKeys == "vn" && driver.state.isLiteral)
        // Backspace into it deletes one character at a time.
        try driver.send(KeyNotation.events("⌫⌫"))
        #expect(driver.field.string == "ban Việt N")
        #expect(driver.outputs.suffix(2).allSatisfy { $0.action == .passThrough })
        // Committing it again keeps what is on screen; it is never expanded again.
        try driver.type(" ")
        #expect(driver.field.string == "ban Việt N " && driver.outputs.last?.decision == .macro)
    }

    @Test func toggleAfterBackspaceBringsTheSpanBack() throws {
        // ENG-R1104, ENG-R704 path: Backspace re-opens the expansion, the toggle shows the span as typed.
        var driver = try Committing.driver("Vn ⌫⎋", resources: Self.resources)
        #expect(driver.field.string == "Vn" && driver.state.activeRawKeys == "Vn")
        // The next boundary keeps the span: the user asked for it.
        try driver.type(" ")
        #expect(driver.field.string == "Vn ")
        #expect(try text("ad. ⌫⎋ ") == "ad. ")
        #expect(try text("@@ ⌫⎋\n") == "@@\n")
        // Keys typed into the expansion are part of its raw keys.
        #expect(try text("vn ⌫s⎋") == "vns")
    }

    @Test func userRestoredTokenIsNotExpanded() throws {
        // `ddc` composes `đc`; the toggle restores `ddc`; the space does not expand it.
        #expect(try text("ddc ") == "đặc ")
        #expect(try text("ddc⎋ ") == "ddc ")
    }

    @Test func expansionsWithNewlinesAndEmptyExpansions() throws {
        var driver = try Committing.driver("sig ", resources: Self.resources)
        #expect(driver.field.string == "Trân trọng,\nKal ")
        try driver.send(KeyNotation.events("⌫⌫⌫⌫"))
        #expect(driver.field.string == "Trân trọng,\n")
        driver = try Committing.driver("a zz ", resources: Self.resources)
        #expect(driver.field.string == "a  ")
        try driver.send(KeyNotation.events("⌫⌫"))
        #expect(driver.field.string == "a" && driver.state.activeDisplay == "a")
    }

    @Test func expansionOutsideTheBasicMultilingualPlane() {
        // Edits that remove an expansion count clusters and UTF-16 units separately (ENG-R630, ENG-R631).
        var session = Session(engine: Engine(configuration: EngineConfiguration(), resources: Self.resources))
        for key in "smile " { _ = session.handle(.key(KeyInput(key))) }
        _ = session.handle(.backspace)
        #expect(session.state.activeDisplay == "\u{1F600}")
        let output = session.handle(.restoreToggle)
        #expect(output.action == .edit(TextEdit(deleteCount: 1, deleteUTF16Count: 2, insert: "smile"), thenPassThrough: false))
    }

    @Test func emptyTableNeverMatches() throws {
        #expect(try Committing.text("vn dc @@ ") == "vn dc @@ ")
    }
}
