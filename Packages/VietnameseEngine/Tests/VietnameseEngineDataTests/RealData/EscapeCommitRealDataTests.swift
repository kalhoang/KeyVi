// SPDX-License-Identifier: MPL-2.0
//
// Rule L4 of 8.1 as amended by the product owner on 17/11/2026 (ENG-R801, REG-37) with the bundled data. The report:
// `leecher` + space gave `lecher`. Telex shows `lêch`, the third `e` escapes the circumflex (ENG-R412, ENG-R440) and
// the old L4 kept the escaped form because neither `lecher` nor `leecher` is in the lexicon; a sweep of
// /usr/share/dict/words found about 4,600 such words. A second group had both forms English and kept the escaped one
// (`off` -> `of`, `dessert` -> `desert`). The product owner chose "by context" for that group: in an English sentence
// the typed word, alone or in a Vietnamese sentence the deliberate escape; and an escape that was not needed (the keys
// of the escaped form alone already commit it) restores the keys in any context.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("Rule L4 with the bundled data (ENG-R801, REG-37)")
struct EscapeCommitRealDataTests {
    static func text(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(typoCorrection: false))
        throws -> String
    {
        var driver = EngineDriver(configuration: configuration, resources: try RealData.resources())
        try driver.send(KeyNotation.events(keys))
        return driver.field.string
    }

    /// The configurations of the sweep: the default, the code context as the terminal rules set it (PLT-R357) and
    /// the collision rules off (ENG-R829).
    static let configurations = [
        EngineConfiguration(typoCorrection: false),
        EngineConfiguration(appContext: .code, lookaheadRevision: false, typoCorrection: false),
        EngineConfiguration(lookaheadRevision: false, typoCorrection: false),
    ]

    @Test(
        "Neither form English and the display went on after the escape: the keys are restored",
        arguments: [
            "leecher", "cheeseburger", "coffeehouse", "cookout", "beefsteak", "deepener", "cheeper", "breeches",
            "beechen", "Leecher", "COFFEEHOUSE",
        ])
    func multiSyllableWordsCommitAsTyped(_ word: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.text(word + " ", configuration) == word + " ", "\(configuration)")
        }
    }

    @Test(
        "Both forms English, the escape was not needed: the keys are restored in any context",
        arguments: ["pass", "brass", "dessert", "barred", "barring", "corral", "duress", "puss", "chaffing"])
    func escapeNotNeeded(_ word: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.text(word + " ", configuration) == word + " ", "\(configuration)")
            #expect(try Self.text("tooi " + word + " ", configuration) == "tôi " + word + " ", "\(configuration)")
        }
    }

    @Test(
        "Both forms English, the escape was needed: alone and in Vietnamese the escaped form, in English the keys",
        arguments: [("off", "of"), ("mess", "mes"), ("mass", "mas"), ("hiss", "his"), ("ass", "as")])
    func escapeNeeded(_ word: String, _ escaped: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.text(word + " ", configuration) == escaped + " ", "\(configuration)")
            #expect(try Self.text("tawts " + word + " ", configuration) == "tắt " + escaped + " ", "\(configuration)")
            #expect(try Self.text("and " + word + " ", configuration) == "and " + word + " ", "\(configuration)")
        }
    }

    @Test(
        "The product owner's sentences",
        arguments: [
            ("turn off the light ", "turn off the light "), ("tawts off ddi ", "tắt of đi "), ("off ", "of "),
            ("tooi pass moon ", "tôi pass môn "), ("ass ", "as "), ("dessert ", "dessert "), ("leecher ", "leecher "),
            ("what a mess ", "what a mess "), ("kiss my ass ", "kiss my ass "), ("critical mass ", "critical mass "),
        ])
    func productOwnerSentences(_ keys: String, _ expected: String) throws {
        #expect(try Self.text(keys) == expected)
    }

    // MARK: - 13.9.5

    struct Row: Sendable, CustomStringConvertible {
        let id: String
        let keys: String
        let text: String
        let decided: String
        var description: String { id }
    }

    /// The rows of 13.9.5, read from the spec in the repository.
    static let rows: [Row] = {
        let url = TestPaths.repoRoot.appendingPathComponent("spec/01-engine.md")
        guard let spec = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inSection = false
        var rows: [Row] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { inSection = line.hasPrefix("#### 13.9.5") }
            guard inSection, line.hasPrefix("| X") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 4 else { continue }
            func unquote(_ cell: String) -> String { cell.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            rows.append(Row(id: cells[0], keys: unquote(cells[1]), text: unquote(cells[2]), decided: cells[3]))
        }
        return rows
    }()

    @Test("13.9.5 has its 39 rows")
    func tableIsComplete() {
        #expect(Self.rows.map(\.id) == (1...39).map { String(format: "X%02d", $0) })
    }

    /// 13.9.5: the rows that need the phrase or the English-lean word, which the collision rules switch on.
    static let collisionRuleRows: Set<String> = ["X06", "X08", "X25", "X26", "X27"]

    @Test("ENG-R804: every row of 13.9.5", arguments: rows)
    func row(_ row: Row) throws {
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: false), resources: try RealData.resources())
        try driver.send(KeyNotation.events(row.keys + " "))
        #expect(driver.field.string == row.text, "\(row.id): \(driver.field.string.debugDescription)")
        #expect(driver.outputs.contains { $0.decision?.rule == .escape }, "\(row.id): L4 decided a word")
        let terminal = try Self.text(row.keys + " ", Self.configurations[1])
        if Self.collisionRuleRows.contains(row.id) {
            #expect(terminal != row.text, "\(row.id): the row needs the collision rules")
        } else {
            #expect(terminal == row.text, "\(row.id): \(terminal.debugDescription)")
        }
    }

    /// `Tests/VietnameseEngineTests/Corpus/escape-regression.txt`: keys, committed text, source, outcome.
    static func regressionRows() throws -> [(keys: String, committed: String, outcome: String)] {
        let url = TestPaths.packageRoot.appendingPathComponent(
            "Tests/VietnameseEngineTests/Corpus/escape-regression.txt")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { line in
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cells.count == 4, ["restore", "keep"].contains(cells[3]) else {
                    throw TestFailure("escape-regression.txt: malformed row \(line)")
                }
                return (cells[0], cells[1], cells[3])
            }
    }

    @Test("REG-37 regression corpus: words of SCOWL and web2 that the old L4 kept as an escaped form")
    func regressionCorpus() throws {
        let rows = try Self.regressionRows()
        #expect(rows.count > 300)
        #expect(rows.allSatisfy { ($0.outcome == "restore") == ($0.keys == $0.committed) })
        for configuration in Self.configurations {
            var wrong: [String] = []
            for row in rows where try Self.text(row.keys + " ", configuration) != row.committed + " " {
                wrong.append(row.keys)
            }
            #expect(wrong.isEmpty, "\(configuration): \(wrong)")
        }
        let restored = rows.filter { $0.outcome == "restore" }.count
        print("[REG-37] \(rows.count) corpus words, \(restored) restored, \(rows.count - restored) kept escaped")
    }

    @Test("ENG-R823 known cost: from an empty field the restored pass makes the run English, so moon stays English")
    func restoredWordIsEnglishEvidence() throws {
        // `pass` is restored, so it is an English token; `moon` (`môn`) has an unreviewed `vi` row without a `run: vi`
        // mark, so L10 restores it in that run. The old L4 kept `pas`, an English word on screen, with the same effect.
        #expect(try Self.text("pass moon ") == "pass moon ")
        #expect(try Self.text("pass moon nayf ") == "pass moon này ")
    }

    @Test(
        "ENG-R804 known cost: the English context looks back only, so a neutral word before keeps the escape",
        arguments: [
            ("ok off ", "ok of "), ("50% off ", "50% of "), ("mess up ", "mes up "), ("off topic ", "of topic "),
            ("off and on ", "of and on "), ("Off the record ", "Of the record "),
        ])
    func contextLooksBackOnly(_ keys: String, _ expected: String) throws {
        // `ok` is kept (neutral), so the run is not English and no phrase starts there; a word that only the next token
        // shows to be English keeps the deliberate escape, as `off` typed alone does. The revisions of ENG-R828 do not
        // take a token decided by L4. `mess up`, `off topic` and `Off the record` are parked for a later decision of
        // the product owner (18/11/2026).
        #expect(try Self.text(keys) == expected)
    }

    @Test(
        "ENG-R804 (a): the bundled phrases day off, sale off and a mess are English context (product owner, 18/11/2026)",
        arguments: [
            ("day off ", "day off "), ("a mess ", "a mess "), ("Ee cos sale off 50% ", "Ê có sale off 50% "),
            ("Mai minhf xin day off nhes ", "Mai mình xin day off nhé "),
            ("Phongf nayf a mess quas ", "Phòng này a mess quá "),
        ])
    func bundledPhrasesAreEnglishContext(_ keys: String, _ expected: String) throws {
        // Until 18/11/2026 `day` (Vietnamese), `a` (neutral) and `sale` after Vietnamese words gave no English evidence,
        // so the doubling kept the escapes `day of`, `a mes` and `sale of`. The phrases make the context English (the
        // evidence of L9b), so L4 restores the word typed. The collision rules read phrases only with
        // `lookaheadRevision` on (ENG-R829): the terminal configuration keeps the escape.
        #expect(try Self.text(keys) == expected)
        #expect(try Self.text(keys, Self.configurations[1]) != expected)
    }

    @Test(
        "ENG-R804 (a): with English evidence before the word, the word typed is kept (L10 run or L9b phrase)",
        arguments: ["get 50% off today ", "log off ", "sign off ", "what a mess ", "take off ", "clean up the mess "])
    func englishEvidenceBefore(_ keys: String) throws {
        #expect(try Self.text(keys) == keys)
    }

    // MARK: - REG-40

    @Test(
        "REG-40: the product owner's report, a w doubled out of habit is left out of the restore",
        arguments: [
            ("wwebview ", "webview "), ("wwebsite ", "website "), ("wwebhook ", "webhook "), ("wwiki ", "wiki "),
            ("wwidget ", "widget "), ("wwechat ", "wechat "), ("wwordpress ", "wordpress "), ("Wwebview ", "Webview "),
            ("vieejt wwebview ", "việt webview "),
        ])
    func productOwnerReport(_ keys: String, _ expected: String) throws {
        // 1.0.1-beta.2 committed the raw keys with both `w` (`wwebview`): neither form is English, so (d) restored R.
        for configuration in Self.configurations {
            #expect(try Self.text(keys, configuration) == expected, "\(configuration)")
        }
    }

    @Test(
        "REG-40: what the report found right does not change",
        arguments: [
            ("wwindows ", "windows "), ("wwifi ", "wifi "), ("wwork ", "work "), ("wweb ", "web "), ("wwhat ", "what "),
            ("wwow ", "wow "), ("wwatch ", "watch "), ("wwebpack ", "webpack "), ("wwhatsapp ", "whatsapp "),
            ("wwrapper ", "wrapper "), ("www ", "www "), ("webview ", "webview "), ("website ", "website "),
            ("webhook ", "webhook "), ("powwow ", "powwow "), ("ww ", "w "), ("uww ", "uw "), ("aww ", "aw "),
            ("wwww ", "www "),
        ])
    func reportedRightUnchanged(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.text(keys, configuration) == expected, "\(configuration)")
        }
    }

    @Test("REG-40, 11A: the typed word of the correction is R′, what the screen shows (ENG-R1110, ENG-R1117)")
    func correctionReadsTheKeysWithoutTheDoubling() throws {
        // `wwindwos` shows `windwos`; L4 restores `R′` = `windwos`, which one transposition makes `windows`. Read on
        // `R` = `wwindwos`, no single edit gives a word, so 1.0.1-beta.2 committed `wwindwos`.
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: true), resources: try RealData.resources())
        try driver.send(KeyNotation.events("wwindwos "))
        #expect(driver.field.string == "windows " && driver.outputs.last?.decision == .corrected(.escape))
        // The undo brings back the typed word and names it in the signal, so the never-correct list holds what the
        // next `wwindwos` reads.
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "windwos " && driver.outputs.last?.learning == .neverCorrect(raw: "windwos"))
        var resources = try RealData.resources()
        resources.userNeverCorrect = WordSet(["windwos"])
        var listed = EngineDriver(configuration: EngineConfiguration(typoCorrection: true), resources: resources)
        try listed.send(KeyNotation.events("wwindwos "))
        #expect(listed.field.string == "windwos ")
        // Backspace re-opens the correction and the toggle brings back the typed word; after one more Backspace the
        // token shows `windwo`, which is also its composed form `C`, so the next toggle passes through.
        var reopened = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: true), resources: try RealData.resources())
        try reopened.send(KeyNotation.events("wwindwos ⌫⎋"))
        #expect(reopened.field.string == "windwos")
        try reopened.send(KeyNotation.events("⌫⎋"))
        #expect(reopened.field.string == "windwo")
    }

    /// The keys typed through the invariant checker of 13.6 with the bundled data (ENG-R701, ENG-T31 to ENG-T33),
    /// and the field after them.
    static func checked(_ keys: String, _ configuration: EngineConfiguration) throws -> String {
        let resources = try RealData.resources()
        var checker = InvariantChecker(engine: Engine(configuration: configuration, resources: resources))
        try checker.send(KeyNotation.events(keys))
        try checker.finish()
        var driver = EngineDriver(configuration: configuration, resources: resources)
        try driver.send(KeyNotation.events(keys))
        return driver.field.string
    }

    /// The configurations of the sweep and the default one, where the typo correction is on (ENG-R1119).
    static let configurationsWithCorrection = configurations + [EngineConfiguration(typoCorrection: true)]

    @Test(
        "REG-40: a re-opened token that shows R′ never gains a w it does not show (ENG-R1005, ENG-R701)",
        arguments: [
            ("answwer ⌫⌫ ", "answe "), ("answwer ⌫z ", "answerz "), ("answwer ⌫⌫ ⌫", "answe"),
            ("answwer ⌫⌫ ⌫⌫⌫a ", "ấn "), ("softwware ⌫⌫⌫ ⌫", "softwa"), ("softwware ⌫⌫⌫ ⌫⌫⌫ ", "soft "),
            ("wwebview ⌫Kit ", "webviewKit "), ("wwebview ⌫Kit ⌫", "webviewKit"),
        ])
    func reopenedTokenNeverGainsAW(_ keys: String, _ expected: String) throws {
        // Each commit of the token sets or clears what it shows, so the second re-opening shows the text the first
        // re-opened commit wrote; the invariant checker holds the display to the raw keys shown after every event.
        for configuration in Self.configurationsWithCorrection {
            #expect(try Self.checked(keys, configuration) == expected, "\(configuration)")
        }
    }

    @Test(
        "REG-40: once Backspace took the w doubling the token did not show, a w doubling typed again shows and stays",
        arguments: [
            ("answwer ⌫⌫⌫⌫ww⌫er ", "answer "), ("answwer ⌫⌫⌫⌫wwer ", "answer "), ("answwer ⌫⌫⌫⌫wwere ", "answwere "),
            ("softwware ⌫⌫⌫⌫⌫⌫wware ", "sofwware "), ("softwware ⌫⌫⌫⌫⌫⌫ww⎋ ", "sòw "), ("answwer ⌫⌫⌫⌫ww⌫⌫⌫⌫", "a"),
            ("answwer ⌫⌫ ⌫⌫⌫ww ", "ánw "),
        ])
    func backspacePastTheOmittedDoubling(_ keys: String, _ expected: String) throws {
        // ENG-R1005, ENG-R701: the token holds one `w` doubling at most (the escape is sticky, ENG-R441), so once
        // Backspace removed the one the token did not show, the token shows every raw key again; a `w` doubling typed
        // after that is on screen, and the commit decides the keys as a token typed afresh with them (`ans` + `wwer`
        // gives `answer`, as `answwer` does: (c′)).
        for configuration in Self.configurationsWithCorrection {
            #expect(try Self.checked(keys, configuration) == expected, "\(configuration)")
        }
    }

    @Test(
        "REG-40, 11A: a re-commit of the typed word the toggle took back keeps showing it (ENG-R1005, ENG-R1117)",
        arguments: [
            ("wwindwos ⎋⌫ ⌫", "windwos"), ("wwindwos ⎋⌫.⌫", "windwos"), ("wwindwos ⎋⌫s ⌫", "windwoss"),
            ("wwindwos ⎋⌫ ⌫⌫", "windwo"), ("wwindwos ⌫ ⌫⎋", "windwos"),
            ("wwindwos ⌫ ⌫⎋⌫⎋", "windwo"),
        ])
    func recommittedUndoneCorrectionShowsTheTypedWord(_ keys: String, _ expected: String) throws {
        // `wwindwos` + space gives `windows`, the toggle gives back the typed word `windwos` (`R′`), Backspace re-opens
        // it and the next boundary commits it unchanged (rule L1): the re-opening after that shows `windwos` again. A
        // re-committed correction keeps its typed word the same way, so its toggle still composes every key typed.
        for configuration in Self.configurationsWithCorrection {
            #expect(try Self.checked(keys, configuration) == expected, "\(configuration)")
        }
    }

    @Test("REG-40, 11A: Backspace empties a re-committed typed word one character at a time (ENG-R1005)")
    func recommittedUndoneCorrectionEmptiesCleanly() throws {
        // The first Backspace re-opens the word, seven more delete its seven characters (eight raw keys), the last one
        // finds an empty field.
        for configuration in Self.configurationsWithCorrection {
            #expect(try Self.checked("wwindwos ⎋⌫ ⌫⌫⌫⌫⌫⌫⌫⌫⌫", configuration).isEmpty, "\(configuration)")
        }
    }

    @Test(
        "REG-40, ENG-R904: camel case keys whose w doublings are a habit restore R′ through rule L3b",
        arguments: [
            ("wwebView ", "webView "), ("WwebView ", "WebView "), ("WwordPress ", "WordPress "),
            ("WweChat ", "WeChat "), ("WwhatsApp ", "WhatsApp "), ("WwiFi ", "WiFi "), ("wwebSocket ", "webSocket "),
            ("wwwRoot ", "wwwRoot "), ("dowwnLoad ", "dowwnLoad "), ("wwwexample ", "wwwexample "),
        ])
    func camelCaseHabit(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurationsWithCorrection {
            #expect(try Self.checked(keys, configuration) == expected, "\(configuration)")
        }
    }

    @Test("REG-40, 11A: a one-syllable typo typed with the habit is a deliberate form of (d), no candidate (ENG-R1110)")
    func oneSyllableTypoWithTheHabit() throws {
        #expect(try Self.checked("wwhcih ", EngineConfiguration(typoCorrection: true)) == "whcih ")
        #expect(try Self.checked("whcih ", EngineConfiguration(typoCorrection: true)) == "which ")
    }

    @Test(
        "The deliberate escapes of Telex users and the escape examples of the spec do not change",
        arguments: [
            ("boooong ", "booong "), ("sooocs ", "soóc "), ("nhaamff ", "nhâmf "), ("ddd ", "dd "), ("www ", "www "),
            ("ddid ", "did "), ("uww ", "uw "), ("Ea Karr ", "Ea Kar "), ("Cuw M'garr ", "Cư M'gar "),
            ("Kroong Anaa ", "Krông Ana "), ("tarr ", "tar "), ("hosst ", "host "), ("password ", "password "),
            ("traffic ", "traffic "), ("coffee ", "coffee "), ("tomorrow ", "tomorrow "),
        ])
    func deliberateEscapes(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.text(keys, configuration) == expected, "\(configuration)")
        }
    }
}
