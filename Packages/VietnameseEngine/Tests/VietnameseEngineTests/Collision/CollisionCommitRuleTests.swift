// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The commit-time collision rules (spec 8.1 L9a, L9b, L9c, the `run: vi` exemption of L10 and the
/// English-lean window, ENG-R823, ENG-R825 to ENG-R827, ENG-R863), with the collision fixture.
@Suite("Collision rules at commit (L9a to L9c, ENG-R825 to ENG-R827)")
struct CollisionCommitRuleTests {
    typealias F = CollisionFixture

    @Test("ENG-R825 L9a: `as` before . ! ? or Return keeps á even in an English run")
    func boundaryParticle() throws {
        for boundary in [".", "!", "?", "\n"] {
            let driver = try F.driver("tricky as" + boundary)
            #expect(driver.field.string == "tricky á" + boundary)
            #expect(F.decisions(driver).last == .kept(.boundaryParticle))
        }
        // An ellipsis: the first `.` commits the token.
        #expect(try F.field("tricky as...") == "tricky á...")
        // Any other boundary leaves the English run to rule L10.
        #expect(try F.field("tricky as, ") == "tricky as, ")
        #expect(try F.field("tricky as ") == "tricky as ")
        // `has` is not a boundary particle: `Yes she has.` stays English.
        #expect(try F.field("yes she has.") == "yes she has.")
    }

    @Test("ENG-R825 L9a: a kept boundary particle is neutral for the window")
    func boundaryParticleIsNeutral() throws {
        // [tricky en, á neutral]: still an English run, so `car` is restored by L10.
        let driver = try F.driver("tricky as. car ")
        #expect(driver.field.string == "tricky á. car ")
        #expect(F.decisions(driver).last == .restored(.englishRun))
    }

    @Test("ENG-R826 L9b: the previous one to three tokens and this token start a phrase")
    func phraseLookingBack() throws {
        // `được` makes the window Vietnamese, so only the phrase restores `been` (L10 would not).
        let driver = try F.driver("dduwowcj has been ")
        #expect(F.decisions(driver)[2] == .restored(.phrase))
        // p = 2: the second `as` of `as soon as`.
        let soon = try F.driver("dduwowcj as soon as ")
        #expect(soon.field.string == "được as soon as ")
        #expect(F.decisions(soon)[2] == .restored(.phrase) && F.decisions(soon)[3] == .restored(.phrase))
        // Only single spaces join a phrase.
        #expect(try F.field("dduwowcj has, been ") == "được há, bên ")
        #expect(try F.field("dduwowcj has  been ") == "được há  bên ")
    }

    @Test("ENG-R827: rule L10 never restores a `run: vi` row")
    func runExemption() throws {
        let driver = try F.driver("tricky tows ")
        #expect(driver.field.string == "tricky tớ ")
        #expect(F.decisions(driver).last == .kept(.ambiguityTable))
        // Without the exemption (lookaheadRevision off) the English run restores it.
        #expect(
            try F.field("tricky tows ", configuration: EngineConfiguration(lookaheadRevision: false)) == "tricky tows ")
    }

    @Test("ENG-R823: an unchanged English-lean word (`the`, `my`) counts as English")
    func englishLeanWindow() throws {
        // `The cả` at a line start becomes `The car`.
        #expect(try F.field("The car ") == "The car ")
        #expect(try F.field("my car ") == "my car ")
        // Off, `the` is neutral and the row keeps `cả`.
        #expect(try F.field("The car ", configuration: EngineConfiguration(lookaheadRevision: false)) == "The cả ")
        // A Vietnamese token in the window still wins.
        #expect(try F.field("dduwowcj the car ") == "được the cả ")
    }

    @Test("ENG-R863 L9c: the memory decides a collision word in its context class")
    func learnedMemory() throws {
        let memory = CollisionMemorySnapshot([
            .init(word: "car", context: .afterVietnamese, choice: .english),
            .init(word: "this", context: nil, choice: .english),
        ])
        let resources = F.resources(memory: memory)
        let driver = try F.driver("dduwowcj car ", resources: resources)
        #expect(driver.field.string == "được car ")
        #expect(F.decisions(driver).last == .restored(.learned))
        // Another class: the rules decide.
        #expect(try F.field("car ", resources: resources) == "cả ")
        // The any-context entry applies in every class.
        #expect(try F.field("this ", resources: resources) == "this ")
        #expect(try F.field("dduwowcj this ", resources: resources) == "được this ")
        // A memory vote for Vietnamese is neutral for the window.
        let vietnamese = F.resources(
            memory: CollisionMemorySnapshot([.init(word: "this", context: nil, choice: .vietnamese)]))
        let kept = try F.driver("tricky this car ", resources: vietnamese)
        #expect(kept.field.string == "tricky thí car ")
        #expect(F.decisions(kept)[1] == .kept(.learned) && F.decisions(kept)[2] == .restored(.englishRun))
    }

    @Test("ENG-R863: a context entry in conflict hides the any-context entry")
    func conflictHidesAnyContext() throws {
        let memory = CollisionMemorySnapshot([
            .init(word: "car", context: .sentenceStart, choice: .conflict),
            .init(word: "car", context: nil, choice: .english),
        ])
        #expect(try F.field("car ", resources: F.resources(memory: memory)) == "cả ")
        #expect(try F.field("dduwowcj car ", resources: F.resources(memory: memory)) == "được car ")
    }

    @Test("ENG-R863: the memory reaches L6 to L8 words of the collision list only when it disagrees")
    func memoryOverL7() throws {
        let english = F.resources(memory: CollisionMemorySnapshot([.init(word: "cos", context: nil, choice: .english)]))
        let restored = try F.driver("cos ", resources: english)
        #expect(restored.field.string == "cos " && F.decisions(restored).last == .restored(.learned))
        // A vote that agrees with L7 leaves the rule and the language as they were.
        let agrees = F.resources(
            memory: CollisionMemorySnapshot([.init(word: "cos", context: nil, choice: .vietnamese)]))
        let kept = try F.driver("cos ", resources: agrees)
        #expect(kept.field.string == "có " && F.decisions(kept).last == .kept(.notEnglish))
        // A word that is not on the collision list is never decided by the memory.
        let stranger = F.resources(
            memory: CollisionMemorySnapshot([.init(word: "vieejt", context: nil, choice: .english)]))
        #expect(try F.field("vieejt ", resources: stranger) == "việt ")
        // L8: `does` (display not attested) is not on the list here, so its rule stands.
        #expect(try F.field("does ", resources: stranger) == "does ")
    }

    @Test("ENG-R863: with auto restore off a vote for English keeps the display and names L9c")
    func memoryWithAutoRestoreOff() throws {
        let memory = F.resources(memory: CollisionMemorySnapshot([.init(word: "cos", context: nil, choice: .english)]))
        let driver = try F.driver("cos ", configuration: EngineConfiguration(autoRestore: false), resources: memory)
        #expect(driver.field.string == "có " && F.decisions(driver).last == .kept(.learned))
        let car = F.resources(memory: CollisionMemorySnapshot([.init(word: "car", context: nil, choice: .english)]))
        let kept = try F.driver("car ", configuration: EngineConfiguration(autoRestore: false), resources: car)
        #expect(kept.field.string == "cả " && F.decisions(kept).last == .kept(.learned))
    }

    @Test("ENG-R829: L9c does not depend on lookaheadRevision; L9a and L9b do")
    func memoryWithoutTheContextRules() throws {
        let off = EngineConfiguration(lookaheadRevision: false)
        let memory = F.resources(memory: CollisionMemorySnapshot([.init(word: "car", context: nil, choice: .english)]))
        #expect(try F.field("car ", configuration: off, resources: memory) == "car ")
        #expect(try F.field("tricky as.", configuration: off) == "tricky as.")
        #expect(try F.field("dduwowcj has been ", configuration: off) == "được há bên ")
    }

    @Test("ENG-R825, ENG-R826 rules L9a and L9b decide before the memory")
    func ruleOrder() throws {
        let memory = F.resources(
            memory: CollisionMemorySnapshot([
                .init(word: "as", context: nil, choice: .english),
                .init(word: "been", context: nil, choice: .vietnamese),
            ]))
        #expect(try F.field("tricky as.", resources: memory) == "tricky á.")
        let driver = try F.driver("dduwowcj has been ", resources: memory)
        #expect(F.decisions(driver)[2] == .restored(.phrase))
    }

    @Test("ENG-R802: with auto restore off L9b keeps the token, names itself and is neutral")
    func phraseWithAutoRestoreOff() throws {
        let driver = try F.driver("dduwowcj has been ", configuration: EngineConfiguration(autoRestore: false))
        #expect(driver.field.string == "được há bên ")
        #expect(F.decisions(driver)[2] == .kept(.phrase))
        #expect(driver.state.history.token(beforeNewest: 1)?.language == .neutral)
    }

    @Test("spec/reference-model/boundary.py COLLISION_RUNS: the same rows with the same lists")
    func referenceModelRows() throws {
        var resources = SpecFixtures.commitResources()
        resources.collision = CollisionLists(
            phrases: PhraseList(["has been", "this is", "such as", "as good as"]), boundaryParticles: WordSet(["as"]),
            runExempt: WordSet(["theme"]), englishLean: WordSet(["the", "i"]))
        let rows: [(String, String, CommitDecision)] = [
            ("tricky as.", "tricky á.", .kept(.boundaryParticle)),
            ("tricky as ", "tricky as ", .restored(.englishRun)),
            ("tricky as. car ", "tricky á. car ", .restored(.englishRun)),
            ("and has been ", "and has been ", .restored(.phrase)),
            ("tricky theme ", "tricky thêm ", .kept(.ambiguityTable)),
            ("the car ", "the car ", .restored(.englishRun)),
            ("I car ", "I car ", .restored(.englishRun)),
            ("tricky such as ", "tricky such as ", .restored(.phrase)),
        ]
        for (keys, text, decision) in rows {
            let driver = try F.driver(keys, resources: resources)
            #expect(driver.field.string == text, "\(keys)")
            #expect(F.decisions(driver).last == decision, "\(keys)")
            #expect(F.revisions(driver).isEmpty, "\(keys)")
        }
    }

    @Test("ENG-R827: empty collision lists decide exactly as the rules without them")
    func emptyListsChangeNothing() throws {
        let empty = F.resources(lists: .empty)
        for keys in ["tricky as.", "dduwowcj has been ", "tricky tows ", "The car ", "dduwowcj as hell "] {
            let on = try F.field(keys, resources: empty)
            let off = try F.field(keys, configuration: EngineConfiguration(lookaheadRevision: false), resources: empty)
            #expect(on == off, "\(keys)")
        }
    }
}
