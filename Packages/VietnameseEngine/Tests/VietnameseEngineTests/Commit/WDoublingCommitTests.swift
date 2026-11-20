// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Rule L4 of 8.1 and a `w` doubled out of habit (ENG-R804 as amended by the product owner on 20/11/2026,
/// docs/decisions/0010-pa-decisions-2026-11-19.md item 7, REG-40). Writers used to input methods where `w` alone gives
/// `ư` type a word that starts with `w` as `ww...`: the display shows the word (`wwebview` shows `webview`), and the
/// restore of L4 put back the raw keys with both `w`. A **w doubling** is a Telex escape by the `w` key that comes right
/// after the `w` key whose effect it removes (a horn, a breve or the `ư` of a standalone `w`, ENG-R413); a **standalone
/// w doubling** removed the `ư` of a standalone `w`. `R′` is `R` without the key of each `w` doubling. When `R′` differs
/// from `R`: `R` English decides as before ((a), (c)); `C` English keeps `C` ((b)); (c′) `R′` English restores `R′`;
/// (d) a deliberate form keeps `C`, otherwise `R′` is restored when every `w` doubling is a standalone one, else `R`.
/// Resources: the 13.9 fixtures plus `answer` and `powwow`, and `sofw`, which stands for an English word
/// whose doubled `w` follows a transformed key in a one-syllable display (no word of the bundled lexicon has that shape).
@Suite("Rule L4: a w doubling typed out of habit (ENG-R804, REG-40)")
struct WDoublingCommitTests {
    static let resources: Resources = {
        var resources = SpecFixtures.commitResources()
        resources.english = WordSet(SpecFixtures.englishLexicon + ["answer", "powwow", "sofw"])
        return resources
    }()

    static let telex = ComposerRules(EngineConfiguration(typoCorrection: false))

    static func driver(
        _ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(typoCorrection: false)
    )
        throws -> EngineDriver
    {
        try Committing.driver(keys, configuration, resources: resources)
    }

    static func text(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(typoCorrection: false))
        throws -> String
    {
        try driver(keys, configuration).field.string
    }

    /// The raw indices of the `w` doublings of `keys` and of the standalone ones among them.
    static func doublings(_ keys: String, _ rules: ComposerRules = telex) -> (all: [Int], standalone: [Int]) {
        let composition = Composition(replaying: Array(keys.utf8), rules: rules)
        return (indices(composition.wDoublings), indices(composition.standaloneWDoublings))
    }

    static func indices(_ set: KeySet) -> [Int] { (0..<64).filter { set.contains($0) } }

    // MARK: - The composition records the w doublings

    @Test(
        "Composition records each w doubling and whether it removed the ư of a standalone w",
        arguments: [
            ("ww", [1], [1]), ("Ww", [1], [1]), ("WW", [1], [1]), ("wW", [1], [1]), ("wwebview", [1], [1]),
            ("www", [1], [1]), ("wwww", [1], [1]), ("Twwitter", [2], [2]), ("aww", [2], []), ("uww", [2], []),
            ("powwow", [3], []), ("answwer", [4], []), ("dowwnload", [3], []), ("sofww", [4], []), ("thuoww", [5], []),
        ])
    func compositionRecordsWDoublings(_ keys: String, _ all: [Int], _ standalone: [Int]) {
        let found = Self.doublings(keys)
        #expect(found.all == all && found.standalone == standalone, "\(keys): \(found)")
    }

    @Test("No w doubling: no escape, an escape of another kind or one that is no doubling, a w after e or i")
    func compositionWithoutWDoublings() {
        // `wsaw`: the escape comes after `s` and `a`, so it is no doubling (ENG-R804); `jewwel`: `w` has no target
        // after `e`, so both `w` are letters (4.1).
        for keys in ["", "w", "wa", "webview", "costs", "ass", "aaa", "ddd", "wsaw", "jewwel", "leecher"] {
            #expect(Self.doublings(keys).all.isEmpty, "\(keys)")
        }
    }

    @Test("VNI has no w doubling; with standalone w off only the horn and breve doublings remain")
    func compositionOtherConfigurations() {
        let vni = ComposerRules(EngineConfiguration(inputMethod: .vni, typoCorrection: false))
        for keys in ["ww", "wwebview", "u77", "a88"] { #expect(Self.doublings(keys, vni).all.isEmpty, "\(keys)") }
        let off = ComposerRules(
            EngineConfiguration(inputMethod: .telex(TelexOptions(standaloneW: false)), typoCorrection: false))
        for keys in ["ww", "wwebview", "www"] { #expect(Self.doublings(keys, off).all.isEmpty, "\(keys)") }
        #expect(Self.doublings("aww", off).all == [2] && Self.doublings("aww", off).standalone.isEmpty)
    }

    @Test("Backspace and replay keep the record of the remaining keys (ENG-R601, ENG-R711)")
    func backspaceKeepsTheRecord() {
        var composition = Composition(replaying: Array("wwebview".utf8), rules: Self.telex)
        for _ in 0..<5 { composition.backspace(rules: Self.telex) }
        #expect(composition.rawText == "wwe" && Self.indices(composition.wDoublings) == [1])
        composition.backspace(rules: Self.telex)
        #expect(composition.rawText == "ww" && Self.indices(composition.standaloneWDoublings) == [1])
        // ENG-R711: the escape letter goes with the `w` it undid.
        composition.backspace(rules: Self.telex)
        #expect(composition.rawText.isEmpty && composition.wDoublings.isEmpty)
        composition.append(UInt8(ascii: "w"), rules: Self.telex)
        #expect(composition.wDoublings.isEmpty)
    }

    // MARK: - The decision

    @Test(
        "(d): neither form English, every w doubling a standalone one: R′ is restored",
        arguments: [
            ("wwebview ", "webview "), ("wwiki ", "wiki "), ("Wwebview ", "Webview "), ("WWEBVIEW ", "WEBVIEW "),
            ("vieejt wwebview ", "việt webview "), ("Twwitter ", "Twitter "),
        ])
    func standaloneDoublingsRestoreTheKeysWithoutThem(_ keys: String, _ expected: String) throws {
        let driver = try Self.driver(keys)
        #expect(driver.field.string == expected)
        #expect(driver.outputs.last?.decision == .restored(.escape))
    }

    @Test("(c′): R′ English restores R′, also where C is a deliberate form")
    func keysWithoutTheDoublingEnglish() throws {
        // `answwer` shows `ánwer`: the `s` set the tone before the doubled `w`.
        let driver = try Self.driver("answwer ")
        #expect(driver.field.string == "answer ")
        #expect(driver.outputs.last?.decision == .restored(.escape))
        // `sofww` shows `sòw`, one syllable that ends with the escape (a deliberate form of (d)); (c′) comes first.
        #expect(try Self.text("sofww ") == "sofw ")
    }

    @Test("A horn or breve doubling outside (c′) restores R, and R English decides first (c)")
    func otherDoublingsRestoreTheKeys() throws {
        // `bawwnana` shows `bawnana`: the doubling undid a breve, and English writes `ww` only in compounds.
        #expect(try Self.text("bawwnana ") == "bawwnana ")
        #expect(try Self.text("dowwnload ") == "dowwnload ")
        #expect(try Self.text("powwow ") == "powwow ")
        #expect(try Self.text("www ") == "www ")
    }

    @Test(
        "The deliberate forms do not change (4.7)",
        arguments: [("uww ", "uw "), ("ww ", "w "), ("aww ", "aw "), ("wwww ", "www "), ("Ww ", "w ")])
    func deliberateFormsUnchanged(_ keys: String, _ expected: String) throws {
        #expect(try Self.text(keys) == expected)
        #expect(try Self.driver(keys).outputs.last?.decision == .kept(.escape))
    }

    @Test("The restore edit puts back R′ and then the boundary key (ENG-R803)")
    func restoreEditWritesTheKeysWithoutTheDoubling() throws {
        // `answwer` shows `ánwer`: one edit replaces it with `answer`, then the space passes through.
        let driver = try Self.driver("answwer ")
        guard case .edit(let edit, let thenPassThrough)? = driver.outputs.last?.action else {
            Issue.record("no edit")
            return
        }
        #expect(thenPassThrough && edit.insert.hasSuffix("wer") && !edit.insert.contains("ww"))
        // `wwebview` already shows `webview`: nothing to change, the space passes through.
        #expect(try Self.driver("wwebview ").outputs.last?.action == .passThrough)
    }

    @Test("VNI and Telex with standalone w off: L4 decides as before")
    func otherConfigurationsUnchanged() throws {
        let vni = EngineConfiguration(inputMethod: .vni, typoCorrection: false)
        #expect(try Self.text("wwebview ", vni) == "wwebview ")
        let off = EngineConfiguration(inputMethod: .telex(TelexOptions(standaloneW: false)), typoCorrection: false)
        #expect(try Self.text("wwebview ", off) == "wwebview ")
        #expect(try Self.text("aww ", off) == "aw ")
    }

    @Test("lookaheadRevision off and the code context give the same text; auto restore off keeps C")
    func otherSwitches() throws {
        let configurations = [
            EngineConfiguration(lookaheadRevision: false, typoCorrection: false),
            EngineConfiguration(appContext: .code, lookaheadRevision: false, typoCorrection: false),
            EngineConfiguration(appContext: .code, typoCorrection: false),
        ]
        for configuration in configurations {
            #expect(try Self.text("wwebview ", configuration) == "webview ", "\(configuration)")
            #expect(try Self.text("answwer ", configuration) == "answer ", "\(configuration)")
            #expect(try Self.text("bawwnana ", configuration) == "bawwnana ", "\(configuration)")
        }
        let off = EngineConfiguration(autoRestore: false, typoCorrection: false)
        #expect(try Self.text("answwer ", off) == "ánwer ")
        #expect(try Self.driver("answwer ", off).outputs.last?.decision == .kept(.escape))
    }

    // MARK: - Toggle, history, re-opening, run

    @Test("The restore key while composing still gives R, the keys as typed (ENG-R701)")
    func toggleWhileComposingGivesTheKeysTyped() throws {
        #expect(try Self.text("wwebview⎋") == "wwebview")
        #expect(try Self.text("wwebview⎋ ") == "wwebview ")
        #expect(try Self.text("answwer⎋ ") == "answwer ")
    }

    @Test("The history holds R′ and a re-opened token shows R′, never R (ENG-R1001, ENG-R1002, ENG-R1005)")
    func historyAndReopeningShowTheKeysWithoutTheDoubling() throws {
        var driver = try Self.driver("wwebview ⌫")
        #expect(driver.field.string == "webview" && driver.state.activeDisplay == "webview")
        #expect(driver.state.active?.showsRawKeys == true)
        // Backspace takes one character at a time down to an empty field; the driver checks the field after each.
        for length in (0..<7).reversed() {
            try driver.send(.backspace)
            #expect(driver.field.string == String("webview".prefix(length)), "\(length)")
        }
        // Keys typed into the re-opened token are appended as typed, and the next commit restores R′ again.
        #expect(try Self.text("wwebview ⌫s") == "webviews")
        #expect(try Self.text("wwebview ⌫s ") == "webviews ")
        #expect(try Self.text("answwer ⌫") == "answer")
        // At the boundary the token is decided again on its raw keys at that moment (ENG-R1005): `answwe` is neither
        // English nor `answe`, and (d) restores the keys it shows, `R′`, never a `w` it does not show.
        #expect(try Self.text("answwer ⌫⌫ ") == "answe ")
    }

    /// The keys typed, through the invariant checker of 13.6 (ENG-R701: a restored token shows the raw keys it shows,
    /// ENG-T31, ENG-T32, ENG-T33), and the field after them.
    static func checked(
        _ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(typoCorrection: false)
    ) throws -> String {
        var checker = InvariantChecker(engine: Engine(configuration: configuration, resources: resources))
        try checker.send(KeyNotation.events(keys))
        try checker.finish()
        return try text(keys, configuration)
    }

    @Test(
        "A re-opened token that shows R′ restores R′ again: it never gains a w it does not show (ENG-R1005)",
        arguments: [
            ("answwer ⌫⌫ ", "answe "), ("answwer ⌫z ", "answerz "),
            ("wwebview ⌫⌫ ", "webvie "), ("wwebview ⌫s ", "webviews "),
        ])
    func reopenedTokenRestoresTheKeysItShows(_ keys: String, _ expected: String) throws {
        #expect(try Self.checked(keys) == expected)
        #expect(try Self.driver(keys).outputs.last?.decision == .restored(.escape))
    }

    @Test("Every commit sets or clears what the token shows, so each re-opening shows the text committed (ENG-R701)")
    func secondReopeningShowsTheTextCommitted() throws {
        // The first re-opened commit wrote `answe` (`R′`); the second re-opening shows it, and each Backspace deletes
        // one character of it: the `w` doubling goes with the `w` before it.
        #expect(try Self.checked("answwer ⌫⌫ ⌫") == "answe")
        #expect(try Self.checked("answwer ⌫⌫ ⌫⌫") == "answ")
        #expect(try Self.checked("answwer ⌫⌫ ⌫⌫⌫") == "ans")
        #expect(try Self.checked("answwer ⌫⌫ ⌫⌫a ") == "answa ")
        // A commit that keeps `C` clears it: `ww` composes to the `w` shown, and its deliberate form is kept.
        #expect(try Self.checked("wwebview ⌫⌫⌫⌫⌫⌫⌫ ⌫") == "w")
        // camel case keys typed into a re-opened token: L3b restores `R′` too, so the next re-opening matches it.
        #expect(try Self.checked("wwebview ⌫Kit ") == "webviewKit ")
        #expect(try Self.checked("wwebview ⌫Kit ⌫") == "webviewKit")
        #expect(try Self.checked("wwebview ⌫Kit ⌫⌫⌫⌫ ⌫") == "webview")
        // Down to `answ` the keys compose to `ánw`, a deliberate form whose escape is the last key: (d) keeps it.
        #expect(try Self.checked("answwer ⌫⌫⌫ ") == "ánw ")
    }

    @Test(
        "L3b: camel case keys with a standalone w doubling restore R′ (ENG-R904, REG-40)",
        arguments: [
            ("wwebView ", "webView "), ("WwebView ", "WebView "), ("WwordPress ", "WordPress "),
            ("WweChat ", "WeChat "), ("wwebSocket ", "webSocket "), ("WwhatsApp ", "WhatsApp "),
        ])
    func camelCaseRestoresTheKeysWithoutTheDoubling(_ keys: String, _ expected: String) throws {
        #expect(try Self.checked(keys) == expected)
        #expect(try Self.driver(keys).outputs.last?.decision == .restored(.camelCase))
        let code = EngineConfiguration(appContext: .code, lookaheadRevision: false, typoCorrection: false)
        #expect(try Self.text(keys, code) == expected)
    }

    @Test("A w doubling followed by another w is no habit (`www`, ENG-T12): L3b and L4 restore R as before")
    func wwwKeepsEveryW() throws {
        // `www` typed as it is written shows `ww`; English has no word with `ww` right after a first `w` but `www`.
        #expect(try Self.checked("wwwRoot ") == "wwwRoot ")
        #expect(try Self.checked("wwwexample ") == "wwwexample ")
        // A horn or breve doubling in camel case keys keeps `R`, as in L4 (d).
        #expect(try Self.checked("dowwnLoad ") == "dowwnLoad ")
        #expect(try Self.checked("useState ") == "useState ")
    }

    @Test("A key the restore left out at the end goes with the character before it")
    func backspaceOverAnOmittedKey() throws {
        // `sofww` restores `sofw` (its last key is the doubling): the first Backspace takes the `w` shown and the
        // doubling after it.
        var driver = try Self.driver("sofww ⌫")
        #expect(driver.field.string == "sofw")
        try driver.send(.backspace)
        #expect(driver.field.string == "sof")
        try driver.send(.backspace)
        #expect(driver.field.string == "so")
    }

    @Test("Backspace past the w doubling the token did not show: it shows every raw key again (ENG-R1005, ENG-R701)")
    func backspacePastTheOmittedDoubling() throws {
        // `answwer` restores `answer`; three Backspaces after the re-opening take `r`, `e`, then `w` with the doubling.
        var driver = try Self.driver("answwer ⌫⌫⌫⌫")
        #expect(driver.field.string == "ans" && driver.state.active?.rawText == "ans")
        #expect(driver.state.active?.omitsWDoublings == false && driver.state.active?.showsRawKeys == true)
        // A `w` doubling typed now is on screen: the token shows it, and Backspace takes one key per character.
        try driver.type("ww")
        #expect(driver.field.string == "answw" && driver.state.active?.shownRawText == "answw")
        try driver.send(.backspace)
        #expect(driver.field.string == "answ" && driver.state.active?.rawText == "answ")
        #expect(try Self.checked("answwer ⌫⌫⌫⌫ww⌫er ") == "answer ")
        #expect(try Self.checked("answwer ⌫⌫⌫⌫ww⌫⌫⌫⌫") == "a")
        #expect(try Self.checked("answwer ⌫⌫ ⌫⌫⌫ww ") == "ánw ")
    }

    @Test("The toggle right after the commit passes through (ENG-R703); after the re-opening it gives C (ENG-R704)")
    func toggleAfterTheCommit() throws {
        var driver = try Self.driver("answwer ⎋")
        #expect(driver.field.string == "answer " && driver.outputs.last?.action == .passThrough)
        driver = try Self.driver("answwer ⌫⎋")
        #expect(driver.field.string == "ánwer")
        #expect(driver.state.active?.userChoice == .kept)
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "ánwer" && driver.outputs.last?.action == .passThrough)
        try driver.type(" ")
        #expect(driver.field.string == "ánwer " && driver.outputs.last?.decision == .kept(.userChoice))
        // `wwebview` shows `webview`, which is also C: the toggle has nothing to give back.
        driver = try Self.driver("wwebview ⌫⎋")
        #expect(driver.field.string == "webview" && driver.outputs.last?.action == .passThrough)
    }

    @Test("The run language counts the token as restored (ENG-R823)")
    func runLanguage() throws {
        // `webview` is English evidence: `this` (row `vi`) is restored by L10 after it.
        #expect(try Self.text("wwebview this ") == "webview this ")
        #expect(try Self.text("answwer this ") == "answer this ")
    }
}
