// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

private func requireSendable<T: Sendable>(_: T.Type) {}
private func requireHashable<T: Hashable & Sendable>(_: T.Type) {}

/// The contract of spec 12.2 beyond behaviour: conformances (ENG-R1203), defaults (ENG-R103 to ENG-R106,
/// ENG-R510, ENG-R1001) and the closed option set (ENG-R450).
@Suite("Public API contract (12.2)")
struct PublicAPITests {
    @Test("ENG-R1203 every public type is Sendable, the listed value types Hashable")
    func conformances() {
        // Compile-time checks: this test does not build if a conformance is missing.
        requireSendable(Engine.self)
        requireSendable(Session.self)
        requireSendable(Resources.self)
        requireSendable(WordSet.self)
        requireSendable(MacroTable.self)
        requireSendable(Orthography.self)
        requireHashable(InputMethod.self)
        requireHashable(TelexOptions.self)
        requireHashable(ToneStyle.self)
        requireHashable(AppContext.self)
        requireHashable(EngineConfiguration.self)
        requireHashable(KeyInput.self)
        requireHashable(ResetReason.self)
        requireHashable(EngineEvent.self)
        requireHashable(TextEdit.self)
        requireHashable(KeyAction.self)
        requireHashable(CommitRule.self)
        requireHashable(CommitDecision.self)
        requireHashable(MacroTable.Entry.self)
        requireHashable(MacroTable.ValidationError.self)
        requireHashable(LearningSignal.self)
        requireHashable(EngineOutput.self)
        requireHashable(EngineState.self)
        requireHashable(Language.self)
        requireHashable(Validity.self)
        requireHashable(Tone.self)
        requireHashable(SyllableAnalysis.self)
        // The collision API (ENG-R825 to ENG-R866).
        requireSendable(PhraseList.self)
        requireSendable(CollisionLists.self)
        requireHashable(VietnameseReadingKind.self)
        requireHashable(CollisionContext.self)
        requireHashable(CollisionVote.self)
        requireHashable(CollisionMemorySnapshot.self)
        requireHashable(CollisionMemorySnapshot.Vote.self)
        requireHashable(CollisionSignal.self)
        requireHashable(CollisionSignal.Strength.self)
        requireHashable(RevisionReason.self)
    }

    @Test("Defaults: Telex with standalone w on and brackets off, traditional, auto restore on, history 16")
    func defaults() {
        let configuration = EngineConfiguration()
        // ENG-R103, ENG-R104.
        #expect(configuration.inputMethod == .telex(TelexOptions(standaloneW: true, bracketKeys: false)))
        #expect(configuration.toneStyle == .traditional)  // ENG-R105, ENG-R510
        #expect(configuration.autoRestore)  // ENG-R106
        #expect(configuration.appContext == .general)  // ENG-R850
        #expect(configuration.historyLimit == 16)  // ENG-R1001
        #expect(configuration.lookaheadRevision)  // ENG-R829
        #expect(EngineConfiguration(historyLimit: 0).historyLimit == 1)  // 12.2: minimum 1
        #expect(EngineState.initial.historyCount == 0 && EngineState.initial.activeDisplay.isEmpty)
        #expect(MacroTable.empty.triggerCount == 0)  // ENG-R110: the engine ships with an empty table
    }

    @Test("ENG-R450 no other engine option in v1")
    func closedOptionSet() {
        let configurationFields = Mirror(reflecting: EngineConfiguration()).children.compactMap(\.label)
        // ENG-R829: `lookaheadRevision` is the host's switch for the collision rules, not a user option of the
        // composition (ENG-R450 is about composition options).
        #expect(
            configurationFields == [
                "inputMethod", "toneStyle", "autoRestore", "appContext", "historyLimit", "lookaheadRevision",
            ])
        let telexFields = Mirror(reflecting: TelexOptions()).children.compactMap(\.label)
        #expect(telexFields == ["standaloneW", "bracketKeys"])
    }

    @Test("ENG-R1211 an engine's configuration cannot change; a new engine is created instead")
    func configurationIsFixed() {
        let engine = Engine(configuration: EngineConfiguration(toneStyle: .modern), resources: .empty)
        #expect(engine.configuration.toneStyle == .modern)
        var session = Session(engine: engine)
        _ = session.handle(.key(KeyInput("a")))
        let restarted = Session(engine: Engine(configuration: EngineConfiguration(), resources: .empty))
        #expect(restarted.state == .initial)
    }
}

extension MacroTable {
    fileprivate var triggerCount: Int { triggers.count }
}
