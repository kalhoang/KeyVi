// SPDX-License-Identifier: MPL-2.0
import VietnameseEngine
import VietnameseEngineTesting

/// Typing helpers of the typo correction suites (section 11A): the correction fixture of
/// `SpecFixtures.correctionResources` with `typoCorrection` on, keys in `KeyNotation` (`⌫` Backspace, `⎋` the restore
/// toggle, `⟲` a reset).
enum Typo {
    /// The fixture resources, built once.
    static let resources = SpecFixtures.correctionResources()

    static func configuration(
        _ method: InputMethod = .telex(TelexOptions()), appContext: AppContext = .general, autoRestore: Bool = true,
        typoCorrection: Bool = true
    ) -> EngineConfiguration {
        EngineConfiguration(
            inputMethod: method, autoRestore: autoRestore, appContext: appContext, typoCorrection: typoCorrection)
    }

    /// A driver that typed `keys` from an empty field.
    static func typed(
        _ keys: String, _ method: InputMethod = .telex(TelexOptions()), appContext: AppContext = .general,
        autoRestore: Bool = true, typoCorrection: Bool = true, resources: Resources = Typo.resources
    ) throws -> EngineDriver {
        var driver = EngineDriver(
            configuration: configuration(
                method, appContext: appContext, autoRestore: autoRestore, typoCorrection: typoCorrection),
            resources: resources)
        try driver.send(KeyNotation.events(keys))
        return driver
    }

    /// The field after typing `keys`.
    static func field(
        _ keys: String, _ method: InputMethod = .telex(TelexOptions()), appContext: AppContext = .general,
        autoRestore: Bool = true, typoCorrection: Bool = true, resources: Resources = Typo.resources
    ) throws -> String {
        try typed(
            keys, method, appContext: appContext, autoRestore: autoRestore, typoCorrection: typoCorrection,
            resources: resources
        ).field.string
    }

    /// The expectation under Q10 (`CorrectionPolicy.sentenceStart`): `corrected` with the recommendation, the typed
    /// text otherwise.
    static func underQ10(corrected: String, typed: String) -> String {
        CorrectionPolicy.sentenceStart == .corrected ? corrected : typed
    }

    /// The expectation under Q11 (`CorrectionPolicy.commitKeys`) for Return and Tab.
    static func underQ11(corrected: String, typed: String) -> String {
        CorrectionPolicy.commitKeys == .everyCommitKey ? corrected : typed
    }
}

extension EngineDriver {
    /// The decision of the last event that committed something.
    var lastDecision: CommitDecision? { outputs.last { $0.decision != nil }?.decision }

    /// Every learning signal so far.
    var learningSignals: [LearningSignal] { outputs.compactMap(\.learning) }
}
