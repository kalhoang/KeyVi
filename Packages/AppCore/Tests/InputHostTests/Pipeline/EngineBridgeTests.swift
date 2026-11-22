// SPDX-License-Identifier: GPL-3.0-or-later
//
// ADR 0306: settings -> engine configuration, the thirty-two-engine catalog (PLT-R357, ENG-R1119), macros and
// resources.

import AppModel
import Foundation
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct EngineBridgeConfigurationTests {
    private func settings(_ change: (inout EffectiveSettings) -> Void = { _ in }) -> EffectiveSettings {
        var settings = DefaultSettings.v1
        change(&settings)
        return settings
    }

    /// D1, D5, D6: Telex carries its options; VNI has none.
    @Test func typingMethodAndTelexOptions() {
        let telex = EngineBridge.configuration(
            for: settings {
                $0.telexStandaloneW = false
                $0.telexBracketKeys = true
            }, variant: .default)
        #expect(telex.inputMethod == .telex(TelexOptions(standaloneW: false, bracketKeys: true)))
        let vni = EngineBridge.configuration(for: settings { $0.typingMethod = .vni }, variant: .default)
        #expect(vni.inputMethod == .vni)
    }

    /// D2.
    @Test func tonePlacement() {
        #expect(EngineBridge.configuration(for: settings(), variant: .default).toneStyle == .traditional)
        let modern = EngineBridge.configuration(for: settings { $0.tonePlacement = .modern }, variant: .default)
        #expect(modern.toneStyle == .modern)
    }

    /// D4 and the rule feature both have to allow English restore.
    @Test(arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func englishRestoreNeedsSettingAndVariant(setting: Bool, variant: Bool, expected: Bool) {
        let configuration = EngineBridge.configuration(
            for: settings { $0.englishRestore = setting },
            variant: EngineVariant(appContext: .general, englishRestore: variant, macros: true))
        #expect(configuration.autoRestore == expected)
    }

    /// ENG-R850: the rule's engine context selects the app context.
    @Test func appContextFollowsTheVariant() {
        let code = EngineBridge.configuration(
            for: settings(), variant: EngineVariant(appContext: .code, englishRestore: true, macros: true))
        #expect(code.appContext == .code)
        #expect(EngineBridge.configuration(for: settings(), variant: .default).appContext == .general)
    }

    /// ENG-R829, PLT-R357: `lookaheadRevision` = the rule's `features.lookaheadRevision` (the variant) AND D29, in
    /// every combination of the other variant bits.
    @Test(arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func lookaheadRevisionIsTheRuleFlagAndD29(rule: Bool, d29: Bool, expected: Bool) {
        var effective = settings()
        effective.lookaheadRevision = d29
        for variant in EngineVariant.catalogOrder where variant.lookaheadRevision == rule {
            #expect(EngineBridge.configuration(for: effective, variant: variant).lookaheadRevision == expected)
        }
    }

    /// ENG-R829, ENG-R850, REG-36: `lineStartRevision` (RV5 of the code context) is D29 alone. The rules turn
    /// `features.lookaheadRevision` off in every code-context app, where the restore key is off (PLT-R357), so a
    /// Vietnamese sentence typed in iTerm2 that starts with `tar` gets `tả` once the next word is typed.
    @Test(arguments: [true, false])
    func lineStartRevisionIsD29Alone(d29: Bool) {
        var effective = settings()
        effective.lookaheadRevision = d29
        for variant in EngineVariant.catalogOrder {
            #expect(EngineBridge.configuration(for: effective, variant: variant).lineStartRevision == d29)
        }
        let terminal = EngineVariant(appContext: .code, englishRestore: true, macros: true, lookaheadRevision: false)
        let configuration = EngineBridge.configuration(for: effective, variant: terminal)
        #expect(!configuration.lookaheadRevision)
        // `tar` is English and code-only; `tả` and `thử` are attested (the shape of the bundled data, ENG-R850).
        let resources = Resources(
            english: WordSet(["tar"]), techAlways: WordSet([]), techCodeOnly: WordSet(["tar"]),
            attestedSyllables: WordSet(["tả", "thử"]), ambiguity: ["tar": .vietnamese], userKeepRaw: WordSet([]),
            userKeepVietnamese: WordSet([]))
        #expect(Self.typed("tar thuwr ", configuration, resources) == (d29 ? "tả thử " : "tar thử "))
        // A first word in sentence case committed by a space starts a sentence: L9 leaves it to the rules after it
        // at its own commit, whatever D29 says (ENG-R850 as amended by the product owner on 16/11/2026).
        #expect(Self.typed("Tar thuwr ", configuration, resources) == "Tả thử ")
    }

    /// ENG-R1119, PRD-R80: the engine corrects only where the user's D30 and D4, the rule's `englishRestore` and
    /// `restoreHotkey` (the catalog variant) and the user's D8 all allow it, so no word is corrected where the restore
    /// key cannot undo it. Every one of the 2^5 combinations.
    @Test(arguments: 0..<32)
    func typoCorrectionIsD30AndD4AndTheRuleSwitchesAndTheRestoreKey_ENGR1119(_ bits: Int) {
        let (d30, d4, rule, ruleKey, d8) = (bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0, bits & 16 != 0)
        let effective = settings {
            $0.typoCorrection = d30
            $0.englishRestore = d4
            $0.restoreHotkey = d8 ? .key(.escape) : nil
        }
        let variant = EngineVariant(appContext: .general, englishRestore: rule, macros: true, restoreHotkey: ruleKey)
        let configuration = EngineBridge.configuration(for: effective, variant: variant)
        #expect(configuration.typoCorrection == (d30 && d4 && rule && ruleKey && d8))
    }

    /// D8 counts by its on or off state only: any binding turns it on.
    @Test func anyRestoreKeyBindingCountsAsOn_ENGR1119() {
        let rebound = settings { $0.restoreHotkey = .modifierTap(.rightCommand) }
        #expect(EngineBridge.configuration(for: rebound, variant: .default).typoCorrection)
        #expect(EngineBridge.configuration(for: settings(), variant: .default).typoCorrection)
    }

    /// The field after typing `keys` into a fresh session.
    private static func typed(_ keys: String, _ configuration: EngineConfiguration, _ resources: Resources) -> String {
        var session = Session(engine: Engine(configuration: configuration, resources: resources))
        var field = ""
        for character in keys {
            let output = session.handle(.key(KeyInput(character)))
            field = Self.apply(output, character: character, to: field)
        }
        return field
    }

    /// The text after one key: the edit, then the key when it passes through.
    private static func apply(_ output: EngineOutput, character: Character, to field: String) -> String {
        var text = field
        switch output.action {
        case .passThrough:
            text.append(character)
        case .edit(let edit, let thenPassThrough):
            text.removeLast(min(edit.deleteCount, text.count))
            text += edit.insert
            if thenPassThrough { text.append(character) }
        }
        return text
    }
}

@Suite struct EngineCatalogTests {
    private static let allVariants: [EngineVariant] = EngineVariant.catalogOrder

    @Test func catalogHoldsOneEnginePerVariant() {
        let catalog = EngineBridge.catalog(settings: DefaultSettings.v1, resources: .empty)
        for variant in Self.allVariants {
            let engine = catalog.engine(for: variant)
            #expect(engine.configuration == EngineBridge.configuration(for: DefaultSettings.v1, variant: variant))
        }
        #expect(Set(Self.allVariants.map(\.catalogIndex)) == Set(0..<32))
        #expect(Set(Self.allVariants).count == 32)
        #expect(Set(Self.allVariants.map(\.restoreHotkey)) == [false, true])
    }

    /// Bit 4 is the rule's `restoreHotkey` (ENG-R1119): every slot index maps to a variant and back.
    @Test func variantIndexRoundTrips() {
        for index in 0..<32 { #expect(EngineVariant(catalogIndex: index).catalogIndex == index) }
        #expect(EngineVariant.catalogSize == 32)
        var panel = EngineVariant.default
        panel.restoreHotkey = false
        #expect(panel.catalogIndex != EngineVariant.default.catalogIndex)
        #expect(EngineVariant(catalogIndex: panel.catalogIndex) == panel)
    }

    /// Review of the API stage (19/11/2026): a variant without the restore key used to share the slot of the one with
    /// it, so a catalog built for it handed out the fallback engine. Each has its own engine now.
    @Test func aVariantWithoutTheRestoreKeyGetsItsOwnEngine() {
        var panel = EngineVariant.default
        panel.restoreHotkey = false
        let own = Engine(
            configuration: EngineConfiguration(toneStyle: .modern, typoCorrection: false), resources: .empty)
        let other = Engine(configuration: EngineConfiguration(typoCorrection: false), resources: .empty)
        let catalog = EngineCatalog(engines: [panel: own, .default: other])
        #expect(catalog.engine(for: panel).configuration.toneStyle == .modern)
        #expect(catalog.engine(for: .default).configuration.toneStyle == .traditional)
        let only = EngineCatalog(engines: [panel: own])
        #expect(only.engine(for: panel).configuration == own.configuration)
        let built = EngineBridge.catalog(settings: DefaultSettings.v1, resources: .empty)
        #expect(!built.engine(for: panel).configuration.typoCorrection)
        #expect(built.engine(for: .default).configuration.typoCorrection)
    }

    /// Review Focus 5 of the plan: the thirty-two engines share the correction data instead of copying it, or memory
    /// and the rebuild time double. Checked on the guard filter's bit storage, which every engine must hold as one
    /// buffer; the shared `Resources.correctionIndex` is pinned by `thirtyTwoEnginesShareTheCorrectionIndex`.
    @Test func thirtyTwoEnginesShareTheCorrectionData() {
        var resources = Resources.empty
        resources.correction = CorrectionData(
            guardList: ApproximateWordSet(exactly: ["bidden", "keyvi"]), keyboardNeighbours: ["q": "wa"],
            unmarkedShapes: WordSet(["truong"]), vietnameseKeyings: WordSet(["truowng"]))
        let catalog = EngineBridge.catalog(settings: DefaultSettings.v1, resources: resources)
        let base = resources.correction.guardList.bits.withUnsafeBufferPointer { $0.baseAddress }
        for variant in Self.allVariants {
            let bits = catalog.engine(for: variant).resources.correction.guardList.bits
            #expect(bits.withUnsafeBufferPointer { $0.baseAddress } == base)
        }
    }

    /// Review Focus 5 of the plan, ENG-R1122: the thirty-two engines share the one `Resources.correctionIndex` that
    /// `Resources.init` built (a class instance), so the doubled catalog neither copies nor rebuilds it per engine.
    /// Built the way the host builds it: the loaded resources get the user lists, the never-correct list and the
    /// macros (`EngineBridge.resources`), then a variant may drop the macros or the memory. The control at the end
    /// shows the probe tells two indexes apart: assigning `correction` rebuilds the index.
    @Test func thirtyTwoEnginesShareTheCorrectionIndex() throws {
        var loaded = Resources.empty
        loaded.correction = CorrectionData(
            guardList: ApproximateWordSet(exactly: ["bidden", "keyvi"]), keyboardNeighbours: ["q": "wa"],
            unmarkedShapes: WordSet(["truong"]), vietnameseKeyings: WordSet(["truowng"]))
        var settings = DefaultSettings.v1
        settings.keepAsTyped = ["gramar"]
        settings.neverCorrect = ["androdi"]
        let resources = EngineBridge.resources(settings: settings, macros: .empty) { loaded }
        let index = try #require(Self.correctionIndex(of: loaded))
        #expect(Self.correctionIndex(of: resources) == index)
        let catalog = EngineBridge.catalog(settings: settings, resources: resources)
        for variant in Self.allVariants {
            #expect(Self.correctionIndex(of: catalog.engine(for: variant).resources) == index)
        }
        var rebuilt = resources
        rebuilt.correction = resources.correction
        #expect(Self.correctionIndex(of: rebuilt) != index, "assigning the data rebuilds the index")
    }

    /// `Resources.correctionIndex` has the engine package's `package` access, so the test reads the stored instance
    /// by reflection; nil unless it is a class instance (a value would have no identity to share).
    private static func correctionIndex(of resources: Resources) -> ObjectIdentifier? {
        let child = Mirror(reflecting: resources).children.first { $0.label == "correctionIndex" }
        guard let value = child?.value, Mirror(reflecting: value).displayStyle == .class else { return nil }
        return ObjectIdentifier(value as AnyObject)
    }

    /// ENG-R1118: the never-correct list is per user and applies in every app, so every variant's engine carries it,
    /// whatever the variant's other switches.
    @Test func theNeverCorrectListReachesEveryVariant() {
        var settings = DefaultSettings.v1
        settings.neverCorrect = ["androdi"]
        let resources = EngineBridge.resources(settings: settings, macros: .empty) { .empty }
        let catalog = EngineBridge.catalog(settings: settings, resources: resources)
        for variant in Self.allVariants {
            #expect(catalog.engine(for: variant).resources.userNeverCorrect.contains("androdi"))
        }
    }

    /// ENG-R865, PLT-R914: the memory snapshot reaches exactly the variants where English restore runs, and none
    /// when D28 is off.
    @Test func theLearnedMemoryGoesOnlyWhereEnglishRestoreRuns() {
        var resources = Resources.empty
        resources.collisionMemory = CollisionMemorySnapshot([
            .init(word: "as", context: .afterVietnamese, choice: .vietnamese)
        ])
        var settings = DefaultSettings.v1
        let catalog = EngineBridge.catalog(settings: settings, resources: resources)
        for variant in Self.allVariants {
            #expect(catalog.engine(for: variant).resources.collisionMemory.isEmpty == !variant.englishRestore)
        }
        settings.learnCollisionChoices = false
        let off = EngineBridge.catalog(settings: settings, resources: resources)
        #expect(Self.allVariants.allSatisfy { off.engine(for: $0).resources.collisionMemory.isEmpty })
        settings = DefaultSettings.v1
        settings.englishRestore = false
        let noRestore = EngineBridge.catalog(settings: settings, resources: resources)
        #expect(Self.allVariants.allSatisfy { noRestore.engine(for: $0).resources.collisionMemory.isEmpty })
    }

    /// ENG-R1107: only variants that allow macros, with D9 on, carry the macro table.
    @Test func macrosOnlyInVariantsThatAllowThem() {
        var settings = DefaultSettings.v1
        let withMacros = EngineVariant(appContext: .general, englishRestore: true, macros: true)
        let withoutMacros = EngineVariant(appContext: .general, englishRestore: true, macros: false)
        #expect(EngineSettingsMapping.includesMacros(withMacros, settings: settings))
        #expect(!EngineSettingsMapping.includesMacros(withoutMacros, settings: settings))
        settings.macrosEnabled = false
        #expect(!EngineSettingsMapping.includesMacros(withMacros, settings: settings))
    }

    @Test func missingVariantsFallBackToTheDefault() {
        let special = Engine(
            configuration: EngineConfiguration(toneStyle: .modern, typoCorrection: false), resources: .empty)
        let catalog = EngineCatalog(engines: [.default: special])
        for variant in Self.allVariants { #expect(catalog.engine(for: variant).configuration.toneStyle == .modern) }
        let empty = EngineCatalog(engines: [:])
        #expect(empty.engine(for: .default).configuration == EngineConfiguration(typoCorrection: false))
    }

    /// PRD-R27: the publisher's revision travels with the catalog; without one the tap treats every settings
    /// generation as an engine change.
    @Test func catalogCarriesThePublishersRevision() {
        let settings = DefaultSettings.v1
        #expect(EngineBridge.catalog(settings: settings, resources: .empty, revision: 3).revision == 3)
        #expect(EngineBridge.catalog(settings: settings, resources: .empty).revision == nil)
        #expect(EngineCatalog(engines: [:]).revision == nil)
    }

    @Test func factoryBuildsTheEngineOfTheFocusedVariant() {
        let settings = DefaultSettings.v1
        let catalog = EngineBridge.catalog(settings: settings, resources: .empty)
        let snapshot = PipelineFixtures.settings()
        let tap = TapSettingsSnapshot(
            generation: 1, engines: catalog, toggleHotkey: snapshot.toggleHotkey, restoreHotkey: nil,
            macrosInEnglishMode: false, rememberPerApp: true)
        let variant = EngineVariant(appContext: .code, englishRestore: false, macros: false)
        var engine = VietnameseCompositionEngineFactory().makeEngine(for: variant, settings: tap)
        #expect(engine.session.engine.configuration.appContext == .code)
        #expect(!engine.session.engine.configuration.autoRestore)
        _ = engine.handle(.key(KeyInput("a")))
        _ = engine.handle(.reset(.focusChanged))
        #expect(engine.activeDisplay.isEmpty)
    }

    /// ENG-R1211 amendment of 19/11/2026 (PLT-R340): the continued engine is the new variant's prebuilt engine
    /// with the word being typed carried over unchanged, so `vieejt` begun in one field ends as "việt" in a field
    /// whose rule turns `lookaheadRevision` off.
    @Test func aContinuedEngineCarriesTheWordIntoTheNewVariantsEngine() {
        let catalog = EngineBridge.catalog(settings: DefaultSettings.v1, resources: .empty)
        let tap = TapSettingsSnapshot(
            generation: 1, engines: catalog, toggleHotkey: PipelineFixtures.settings().toggleHotkey,
            restoreHotkey: nil, macrosInEnglishMode: false, rememberPerApp: true)
        let factory = VietnameseCompositionEngineFactory()
        var engine = factory.makeEngine(for: .default, settings: tap)
        for character in "viee" { _ = engine.handle(.key(KeyInput(character))) }
        var panel = EngineVariant.default
        panel.lookaheadRevision = false
        var continued = factory.makeEngine(for: panel, settings: tap, continuing: engine)
        #expect(!continued.session.engine.configuration.lookaheadRevision)
        #expect(continued.session.state == engine.session.state)
        for character in "jt" { _ = continued.handle(.key(KeyInput(character))) }
        #expect(continued.activeDisplay == "việt")
    }
}

@Suite struct EngineBridgeMacroTests {
    private func macro(_ trigger: String, _ expansion: String = "x", enabled: Bool = true) -> StoredMacro {
        StoredMacro(trigger: trigger, expansion: expansion, enabled: enabled)
    }

    @Test func disabledMacrosAreLeftOut() {
        let macros = [macro("btw", "by the way"), macro("off", enabled: false), macro("hn", "Hà Nội")]
        let candidates = MacroTableBuilder.candidates(from: macros)
        #expect(candidates.map(\.entry.trigger) == ["btw", "hn"])
        #expect(candidates.map(\.id) == [macros[0].id.uuidString, macros[2].id.uuidString])
        let (_, issues) = EngineBridge.macroTable(from: macros)
        #expect(issues.isEmpty)
    }

    /// PRD-R29: invalid entries are skipped and reported one by one; the rest still build.
    @Test func rejectedEntriesAreDroppedAndReported() {
        let macros = [macro("ok"), macro("bad trigger"), macro("dup"), macro("DUP"), macro("ad"), macro("ad.x")]
        var validations = 0
        let (_, issues) = MacroTableBuilder.build(from: macros) { entries in
            validations += 1
            let triggers = entries.map(\.trigger)
            if triggers.contains("bad trigger") {
                throw MacroTable.ValidationError.invalidTriggerCharacter("bad trigger")
            }
            if triggers.contains("DUP") { throw MacroTable.ValidationError.duplicateTrigger("DUP") }
            if triggers.contains("ad.x") {
                throw MacroTable.ValidationError.shadowedByShorterTrigger(trigger: "ad.x", shorter: "ad")
            }
            return try MacroTable(entries)
        }
        #expect(validations == 4)
        #expect(
            issues == [
                .rejected(macroID: macros[1].id.uuidString, reason: .invalidTriggerCharacter("bad trigger")),
                .rejected(macroID: macros[3].id.uuidString, reason: .duplicateTrigger("DUP")),
                .rejected(
                    macroID: macros[5].id.uuidString, reason: .shadowedByShorterTrigger(trigger: "ad.x", shorter: "ad")),
            ])
    }

    @Test func unknownTriggerInAnErrorRejectsEverythingLeft() {
        let macros = [macro("one"), macro("two")]
        let (_, issues) = MacroTableBuilder.build(from: macros) { _ in throw MacroTable.ValidationError.emptyTrigger("")
        }
        #expect(issues.count == 2)
    }

    @Test func unexpectedErrorsKeepTheTableEmpty() {
        struct Unexpected: Error {}
        let (_, issues) = MacroTableBuilder.build(from: [macro("one")]) { _ in throw Unexpected() }
        #expect(issues.isEmpty)
    }

    @Test func offendingTriggerOfEveryError() {
        let errors: [(MacroTable.ValidationError, String)] = [
            (.emptyTrigger(""), ""), (.triggerTooLong("t"), "t"), (.invalidTriggerCharacter("i"), "i"),
            (.expansionTooLong("e"), "e"), (.duplicateTrigger("d"), "d"),
            (.shadowedByShorterTrigger(trigger: "s.x", shorter: "s"), "s.x"),
        ]
        for (error, trigger) in errors { #expect(error.offendingTrigger == trigger) }
    }
}

@Suite struct EngineBridgeResourcesTests {
    @Test func userListsAndMacrosAreAttached() throws {
        var settings = DefaultSettings.v1
        settings.keepAsTyped = ["xin"]
        settings.keepVietnamese = ["chao"]
        var loads = 0
        let resources = EngineBridge.resources(settings: settings, macros: .empty) {
            loads += 1
            return Resources(
                english: WordSet(["hello"]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
                attestedSyllables: WordSet([]), ambiguity: [:], userKeepRaw: WordSet(["stale"]),
                userKeepVietnamese: WordSet([]))
        }
        #expect(loads == 1)
        #expect(resources.english.contains("hello"))
        #expect(resources.userKeepRaw.contains("xin"))
        #expect(!resources.userKeepRaw.contains("stale"))
        #expect(resources.userKeepVietnamese.contains("chao"))
    }

    /// ENG-R1118: the host passes the never-correct list as `Resources.userNeverCorrect`, replacing whatever the loader
    /// returned, on both entry points (the global lists and the focused app's).
    @Test func theNeverCorrectListIsAttached() {
        var settings = DefaultSettings.v1
        settings.neverCorrect = ["androdi"]
        let stale = { () -> Resources in
            var resources = Resources.empty
            resources.userNeverCorrect = WordSet(["stale"])
            return resources
        }
        let global = EngineBridge.resources(settings: settings, macros: .empty, bundledLoader: stale)
        #expect(global.userNeverCorrect.contains("androdi") && !global.userNeverCorrect.contains("stale"))
        let focused = EngineBridge.resources(
            wordLists: UserWordLists(), neverCorrect: ["gramar"], macros: .empty, bundledLoader: stale)
        #expect(focused.userNeverCorrect.contains("gramar") && !focused.userNeverCorrect.contains("stale"))
    }

    @Test func loaderErrorsPropagate() {
        struct LoadFailed: Error {}
        #expect(throws: LoadFailed.self) {
            try EngineBridge.resources(settings: DefaultSettings.v1, macros: .empty) { throw LoadFailed() }
        }
    }
}

@Suite struct EngineVariantTests {
    /// ENG-R1211 amendment of 19/11/2026: a late focus change continues the word with the new variant's engine only
    /// when the two variants differ in `lookaheadRevision` alone. A different restore key is more than that: the new
    /// engine differs in its typo correction (ENG-R1119), so the word is not carried over.
    @Test func restoreHotkeyIsMoreThanALookaheadDifference() {
        var withoutRevision = EngineVariant.default
        withoutRevision.lookaheadRevision = false
        #expect(withoutRevision.differsOnlyInLookaheadRevision(from: .default))
        var panel = withoutRevision
        panel.restoreHotkey = false
        #expect(!panel.differsOnlyInLookaheadRevision(from: .default))
        var keyOnly = EngineVariant.default
        keyOnly.restoreHotkey = false
        #expect(!keyOnly.differsOnlyInLookaheadRevision(from: .default))
    }
}
