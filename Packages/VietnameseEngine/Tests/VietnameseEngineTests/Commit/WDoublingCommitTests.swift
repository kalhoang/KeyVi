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
}
