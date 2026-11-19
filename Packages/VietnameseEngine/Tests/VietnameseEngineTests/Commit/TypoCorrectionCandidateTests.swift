// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Which tokens the typo correction considers (ENG-R1110) and the letters, length and case it requires (ENG-R1111),
/// section 11A.1, with the correction fixture (`SpecFixtures.correctionResources`).
@Suite("Typo correction: candidates, letters and case (ENG-R1110, ENG-R1111)")
struct TypoCorrectionCandidateTests {
    // MARK: ENG-R1110 (b): the decision of 8.1

    @Test func aTokenShownAsTypedIsACandidate() throws {
        let driver = try Typo.typed("androdi ")
        #expect(driver.field.string == "android ")
        #expect(driver.lastDecision == .corrected(.unchanged))
    }

    @Test func aRestoredTokenIsACandidate() throws {
        let driver = try Typo.typed("whcih ")
        #expect(driver.field.string == "which ")
        #expect(driver.lastDecision == .corrected(.invalid))
    }

    @Test func theClusterCaseNeedsATransformedDisplayKeptByL6() throws {
        let driver = try Typo.typed("gramar ")
        #expect(driver.field.string == "grammar ")  // S02: `grẩm` was on screen, kept by L6
        #expect(driver.lastDecision == .corrected(.extendedSpelling))
        // S52: shown as typed, L0 decides before L6, and the token is Tier B and an unmarked shape.
        #expect(try Typo.field("glong ") == "glong ")
        #expect(try Typo.field("Glong ") == "Glong ")  // S51
        // S50: the cluster case applies to lowercase words only.
        let name = try Typo.typed("ddi Gramar ")
        #expect(name.field.string == "đi Grẩm ")
        #expect(name.lastDecision == .kept(.extendedSpelling))
    }

    @Test func aUserToggleOrListEntryIsNeverACandidate() throws {
        // The toggle before the commit restores `whcih` (L1).
        let toggled = try Typo.typed("whcih⎋ ")
        #expect(toggled.field.string == "whcih ")
        #expect(toggled.lastDecision == .restored(.userChoice))
        // S46: shown as typed (L0 decides before L2), excluded by the list (ENG-R1110 (c)).
        let kept = try Typo.typed("androdi ", resources: SpecFixtures.correctionResources(userKeepRaw: ["androdi"]))
        #expect(kept.field.string == "androdi ")
        #expect(kept.lastDecision == .kept(.unchanged))
        let restoredByList = try Typo.typed(
            "whcih ", resources: SpecFixtures.correctionResources(userKeepRaw: ["whcih"]))
        #expect(restoredByList.field.string == "whcih ")
        #expect(restoredByList.lastDecision == .restored(.userList))
        #expect(
            try Typo.field("whcih ", resources: SpecFixtures.correctionResources(userKeepVietnamese: ["whcih"]))
                == "ưhcih ")
        // S45: the never-correct list (ENG-R1118).
        #expect(
            try Typo.field("androdi ", resources: SpecFixtures.correctionResources(userNeverCorrect: ["androdi"]))
                == "androdi ")
    }

    @Test func aWordOfAnyListIsNeverACandidate() throws {
        #expect(try Typo.field("ability ") == "ability ")  // S41: the lexicon (`agility` would fit)
        #expect(try Typo.field("oauth ") == "oauth ")  // S43: tech-always (`oath`)
        #expect(try Typo.field("gradle ") == "gradle ")  // S44: code-only (`grade`)
        var supplement = Typo.resources
        supplement.collision.supplement = WordSet(["androdi"])
        #expect(try Typo.field("androdi ", resources: supplement) == "androdi ")
        var ambiguity = Typo.resources
        ambiguity.ambiguity["androdi"] = .english
        #expect(try Typo.field("androdi ", resources: ambiguity) == "androdi ")
        // The guard list (ENG-R1120): a word it may hold is never corrected.
        let guarded = SpecFixtures.correctionResources(
            correction: CorrectionData(
                guardList: ApproximateWordSet(exactly: ["androdi"]),
                keyboardNeighbours: SpecFixtures.keyboardNeighbours, unmarkedShapes: WordSet([]),
                vietnameseKeyings: WordSet([])))
        #expect(try Typo.field("androdi ", resources: guarded) == "androdi ")
    }

    @Test func aVietnameseWordOrShapeIsNeverACandidate() throws {
        let chinh = try Typo.typed("chinhs ")
        #expect(chinh.field.string == "chính ")  // S39, kept by L7
        #expect(chinh.lastDecision == .kept(.notEnglish))
        #expect(try Typo.field("truong ") == "truong ")  // S37 (`truing` would fit)
        #expect(try Typo.field("chuop ") == "chuop ")  // S38 (`chop`)
        #expect(try Typo.field("gruop ") == "gruop ")  // S84, the known cost (`group`)
    }

    @Test func aReopenedRestoredOrCorrectedTokenIsNeverACandidate() throws {
        // A token the toggle restored, re-opened by Backspace and committed again stays the user's choice.
        let restored = try Typo.typed("whcih⎋ ⌫ ")
        #expect(restored.field.string == "whcih ")
        #expect(restored.lastDecision == .restored(.userChoice))
        // A corrected token re-opened and committed again is not corrected a second time (ENG-R1117, S73).
        let corrected = try Typo.typed("androdi ⌫ ")
        #expect(corrected.field.string == "android ")
        #expect(corrected.lastDecision == .corrected(.unchanged))
        #expect(corrected.outputs.filter { $0.decision == .corrected(.unchanged) }.count == 2)
    }

    /// ENG-R1110 (b) for every decision of 8.1, on the same token and context: only L0, a restore by a rule other
    /// than L1 and L2, and the lowercase cluster case of L6 are candidates; the abbreviations of L3, the escaped
    /// forms L4 keeps, L7 to L11, the memory (L9c), a revision's words and a macro are not.
    @Test func onlyTheDecisionsOfENGR1110bAreCandidates() throws {
        let configuration = Typo.configuration()
        let corrector = TypoCorrector(resources: Typo.resources, configuration: configuration)
        var driver = EngineDriver(configuration: configuration, resources: Typo.resources)
        try driver.type("androdi")
        let token = try #require(driver.state.active)
        let inputs = CommitInputs(token: token, style: .traditional)
        let context = CommitContext(runIsEnglish: false)
        let rules: [CommitRule] = [
            .unchanged, .userChoice, .userList, .abbreviation, .camelCase, .escape, .toneRemoval, .invalid,
            .extendedSpelling, .notEnglish, .notAttested, .codeContext, .boundaryParticle, .phrase, .learned,
            .englishRun, .ambiguityTable, .techList, .defaultVietnamese,
        ]
        for rule in rules {
            let kept = corrector.correction(for: inputs, decision: .kept(rule), token: token, context: context)
            // `androdi` is no cluster token, so L6 keeping it is not the cluster case.
            #expect((kept != nil) == (rule == .unchanged), "kept(\(rule))")
            let restored = corrector.correction(for: inputs, decision: .restored(rule), token: token, context: context)
            #expect((restored != nil) == (rule != .userChoice && rule != .userList), "restored(\(rule))")
            if let restored { #expect(restored.text == "android" && restored.rule == rule) }
            #expect(
                corrector.correction(for: inputs, decision: .corrected(rule), token: token, context: context) == nil)
        }
        #expect(corrector.correction(for: inputs, decision: .macro, token: token, context: context) == nil)
    }

    @Test func withAutoRestoreOffNothingIsCorrected_ENGR802() throws {
        let driver = try Typo.typed("androdi ", autoRestore: false)
        #expect(driver.field.string == "androdi ")
        #expect(driver.lastDecision == .kept(.unchanged))
        #expect(try Typo.field("whcih ", autoRestore: false) == "ưhcih ")
    }

    @Test("ENG-R1119: with the switch off nothing is corrected and no output carries the correction")
    func withTheSwitchOffNothingIsCorrected_ENGR1119() throws {
        let driver = try Typo.typed("androdi whcih gramar ", typoCorrection: false)
        #expect(driver.field.string == "androdi whcih grẩm ")
        for output in driver.outputs {
            if case .corrected? = output.decision { Issue.record("corrected with the switch off") }
        }
    }

    // MARK: ENG-R1111: letters, length and case

    @Test func fourLettersAreTooFew() throws {
        #expect(try Typo.field("wiht ") == "wiht ")  // S36 (`with` would fit)
        #expect(try Typo.field("eah ") == "eah ")  // S35 (`each`)
    }

    @Test func twentyFiveLettersAreTooMany() throws {
        let word24 = "abcdefghijklmnopqrstuvwx"
        let word25 = word24 + "y"
        var resources = Typo.resources
        resources.english = WordSet(SpecFixtures.englishLexicon + [word24, word25])
        let typo24 = "bacdefghijklmnopqrstuvwx"
        let typo25 = typo24 + "y"
        #expect(try Typo.field(typo25 + " ", resources: resources) == typo25 + " ")
        #expect(try Typo.field(typo24 + " ", resources: resources) == word24 + " ")
    }

    @Test func aDigitOrBracketLetterExcludesTheToken() throws {
        // S58: in Telex the digit commits `androd` and is not a closer.
        #expect(try Typo.field("androd1") == "androd1")
        // A VNI digit is a key of the token: the typed word is not letters only.
        #expect(try Typo.field("andro6di ", .vni) == "andro6di ")
        // A Telex bracket key with the bracket option.
        #expect(try Typo.field("andr[di ", .telex(TelexOptions(bracketKeys: true))) == "andr[di ")
        // Plain letters in VNI are candidates (S27).
        #expect(try Typo.field("androdi ", .vni) == "android ")
    }

    @Test func sentenceCaseOnlyAtASentenceStart() throws {
        #expect(try Typo.field("Androdi ") == Typo.underQ10(corrected: "Android ", typed: "Androdi "))  // S23
        #expect(try Typo.field("xong. Recieve ") == Typo.underQ10(corrected: "xong. Receive ", typed: "xong. Recieve "))
        #expect(try Typo.field("xong: Androdi ") == Typo.underQ10(corrected: "xong: Android ", typed: "xong: Androdi "))
        #expect(try Typo.field("ddi Androdi ") == "đi Androdi ")  // S49: a name
        #expect(try Typo.field("ddi, Androdi ") == "đi, Androdi ")
        #expect(try Typo.field("ANDRODI ") == "ANDRODI ")  // S47
        #expect(try Typo.field("AndroDi ") == "AndroDi ")  // S48
        #expect(try Typo.field("andrOdi ") == "andrOdi ")
    }

    @Test func aChatElongationIsNotATypo() throws {
        #expect(try Typo.field("stilll ") == "stilll ")  // S53 (`still` would fit)
        #expect(try Typo.field("Stilll ") == "Stilll ")
    }
}
