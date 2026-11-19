// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The edit search and the one-word rule (ENG-R1113, ENG-R1114, ENG-R1125), the edit of a correction and the words
/// around it (ENG-R1115, ENG-R1116), with the correction fixture.
@Suite("Typo correction: the one word, the edit and the run (ENG-R1114 to ENG-R1116, ENG-R1125)")
struct TypoCorrectionCommitTests {
    @Test func exactlyOneWordOfAtLeastFourLettersFits_ENGR1114() throws {
        #expect(try Typo.field("androdi ") == "android ")  // S01
        #expect(try Typo.field("helpp ") == "help ")  // S18: a four-letter word is allowed as the correction
        #expect(try Typo.field("gramar ") == "grammar ")  // S02: `grammar` reached by two insertions counts once
        #expect(try Typo.field("thier ") == "thier ")  // S31: `their`, `tier`, `thief`
        #expect(try Typo.field("wierd ") == "wierd ")  // S32: `weird`, `wired`
        #expect(try Typo.field("pleasee ") == "pleasee ")  // S33: `please`, `pleases`, `pleased`
        #expect(try Typo.field("grammer ") == "grammer ")  // S34: no word fits
        #expect(try Typo.field("eah ") == "eah ")  // S35: three letters
    }

    @Test func theCorrectionLexiconIsTheLexiconAndTheLetterOnlyTechAlwaysEntries() throws {
        var resources = Typo.resources
        resources.techAlways = WordSet(SpecFixtures.techAlways + ["kubectl", "mp3plyr"])
        resources.techCodeOnly = WordSet(["chown", "gradle"])
        // A letter-only tech-always entry fits; an entry with a digit is never reached by an edit of letters.
        #expect(try Typo.field("kubetcl ", resources: resources) == "kubectl ")
        #expect(try Typo.field("wifii ") == "wifi ")
        // Never a code-only word or a word of the guard list (ENG-R1114).
        #expect(try Typo.field("gradel ", resources: resources) == "gradel ")  // `gradle` would be the one fit
        let guarded = SpecFixtures.correctionResources(
            correction: CorrectionData(
                guardList: ApproximateWordSet(exactly: ["android"]),
                keyboardNeighbours: SpecFixtures.keyboardNeighbours,
                unmarkedShapes: WordSet([]), vietnameseKeyings: WordSet([])))
        #expect(try Typo.field("androdi ", resources: guarded) == "android ")
        var guardOnly = guarded
        guardOnly.english = WordSet(SpecFixtures.englishLexicon)
        #expect(try Typo.field("androdi ", resources: guardOnly) == "androdi ")
    }

    @Test func vietnameseWithinOneEditBlocksTheCorrection_ENGR1125() throws {
        #expect(try Typo.field("ddi pahir ") == "đi pahir ")  // S75: `phair` (`phải`), not `pair`
        #expect(try Typo.field("pehis ") == "pehis ")  // S76: `phis`, not `penis`
        #expect(try Typo.field("hoand ") == "hoand ")  // S77: `hoanf`, not `hand`
        #expect(try Typo.field("chihns ") == "chihns ")  // S78: `chinhs`, not `chins`
        #expect(try Typo.field("htach ") == "htach ")  // S79: the shape `thach`, not `hatch`
        // `gamar` composes `gẩm` but is no usual-order keying: `gramar` still gives `grammar`.
        #expect(try Typo.field("gramar ") == "grammar ")
        // Without the keyings and the shapes the English word would be the one fit.
        var bare = Typo.resources
        bare.correction = CorrectionData(
            guardList: .empty, keyboardNeighbours: SpecFixtures.keyboardNeighbours, unmarkedShapes: WordSet([]),
            vietnameseKeyings: WordSet([]))
        #expect(try Typo.field("ddi pahir ", resources: bare) == "đi pair ")
        #expect(try Typo.field("htach ", resources: bare) == "hatch ")
    }

    /// ENG-R1115: one `TextEdit` with the committing key passed through. The edit is minimal (ENG-R611): the common
    /// prefix of the display and the correction stays.
    @Test func theEditIsOneTextEditWithThePassThrough_ENGR1115() throws {
        let plain = try Typo.typed("androdi ")
        #expect(
            plain.outputs.last?.action
                == .edit(TextEdit(deleteCount: 2, deleteUTF16Count: 2, insert: "id"), thenPassThrough: true))
        // The cluster case replaces the display `grẩm`, not the raw keys.
        let cluster = try Typo.typed("gramar ")
        #expect(
            cluster.outputs.last?.action
                == .edit(TextEdit(deleteCount: 2, deleteUTF16Count: 2, insert: "ammar"), thenPassThrough: true))
        // A restored token's display is the composed form (`ưhcih`).
        let restored = try Typo.typed("whcih ")
        #expect(
            restored.outputs.last?.action
                == .edit(TextEdit(deleteCount: 5, deleteUTF16Count: 5, insert: "which"), thenPassThrough: true))
    }

    @Test func theCaseOfTheTypedWordIsKept() throws {
        #expect(try Typo.field("Androdi ") == Typo.underQ10(corrected: "Android ", typed: "Androdi "))  // S23
        #expect(try Typo.field("ok. Whcih ") == Typo.underQ10(corrected: "ok. Which ", typed: "ok. Whcih "))
    }

    @Test func aCorrectedTokenCountsAsEnglishForTheRun_ENGR1116() throws {
        let driver = try Typo.typed("androdi ")
        #expect(driver.state.history.token(beforeNewest: 1)?.language == .english)
        // Review Focus 4: the collision word after it is decided by the English run (L10).
        #expect(try Typo.field("androdi as ") == "android as ")
        #expect(try Typo.field("androdi as ", typoCorrection: false) == "androdi á ")
        #expect(try Typo.field("ddi androdi ") == "đi android ")  // S30
    }

    @Test func aCommitNeverBothRevisesAndCorrects_ENGR1116() throws {
        let off = try Typo.typed("cais nayf tricky as androdi ", typoCorrection: false)
        let on = try Typo.typed("cais nayf tricky as androdi ")
        #expect(off.field.string == "cái này tricky á androdi ")
        #expect(on.field.string == "cái này tricky á android ")
        #expect(on.outputs.last?.revision == nil && on.lastDecision == .corrected(.unchanged))
        // A corrected token is no collision word: the next commit does not revise it either.
        let next = try Typo.typed("androdi nayf ")
        #expect(next.outputs.allSatisfy { $0.revision == nil })
        #expect(next.outputs.allSatisfy { $0.collisionSignals.isEmpty })
    }

    /// Q11 (`CorrectionPolicy.commitKeys`, ADR 0010 item 2): the correction is decided at every committing key,
    /// Return and Tab included (ENG-R1116); 13.12 has no Tab row, so this test keeps Tab.
    @Test func theDecisionIsTheSameAtEveryCommittingKey_Q11() throws {
        for key in ["\n", "\t"] {
            let driver = try Typo.typed("androdi" + key)
            if CorrectionPolicy.commitKeys == .everyCommitKey {
                #expect(driver.field.string == "android" + key)
                #expect(driver.lastDecision == .corrected(.unchanged))
            } else {
                #expect(driver.field.string == "androdi" + key)
                #expect(driver.lastDecision == .kept(.unchanged))
            }
        }
        for key in [" ", ".", ","] {
            let driver = try Typo.typed("androdi" + key)
            #expect(driver.lastDecision == .corrected(.unchanged))
        }
    }
}
