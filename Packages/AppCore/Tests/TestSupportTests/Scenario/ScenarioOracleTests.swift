// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R11 scenario expectations checked against the real engine (ScenarioTextOracle): every TestHost scenario that
// types into a plain native field on the ABC layout must expect exactly what the engine produces under the
// scenario's configuration (method plus app profile). The 200-common-words scenarios are golden files derived from
// data/derived/attested-candidates.tsv (frequency-ordered tokens of the pinned legal corpus, ADR 0200); run the
// suite with UPDATE_SCENARIO_GOLDENS=1 to rewrite them after a data or engine change.

import AppModel
import Foundation
import SettingsStore
import Testing
import VietnameseEngine

@testable import TestSupport

private let scenariosDirectory = repositoryRoot.appendingPathComponent("compat/scenarios")
private let profilesDirectory = scenariosDirectory.appendingPathComponent(AppProfileLoader.directoryName)

/// Targets of this checkout (TestHost resolves through scripts/brand.env).
func repositoryTargets() throws -> HarnessTargets {
    HarnessTargets.resolve(
        repository: repositoryRoot,
        brandEnvironment: try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/brand.env"), encoding: .utf8))
}

func repositoryProfiles() throws -> [AppProfile] {
    try AppProfileLoader.load(directory: profilesDirectory, fileSystem: LocalFileSystem())
}

enum OracleFields {
    /// Native TestHost fields that behave like a plain Cocoa field.
    static let plain: Set<String> = [
        "testhost.native.textField", "testhost.native.textView", "testhost.native.password",
        "testhost.second.textField", "testhost.second.textView", "testhost.second.plainField",
        "testhost.second.escapeField",
    ]
    /// TestHost's Window menu (TestHostApp.swift).
    static let focusShortcuts = [
        "command+1": "testhost.native.textField", "command+2": "testhost.second.textField",
        "command+3": "testhost.sim.addressBar",
    ]

    /// Fields where keys pass through: the secure field (PLT-R387) and fields a profile gives `passThrough`.
    static func passThrough(_ profile: AppProfile?) -> Set<String> {
        var fields: Set<String> = ["testhost.native.password"]
        for override in profile?.ruleOverrides ?? [] {
            guard override.rule["action"]?["strategy"]?.stringValue == "passThrough",
                case .array(let identifiers)? = override.rule["match"]?["ax"]?["identifiers"]
            else { continue }
            fields.formUnion(identifiers.compactMap(\.stringValue))
        }
        return fields
    }

    /// The scenario types into a plain field with secure input off on the ABC layout and checks its text.
    static func checkable(_ scenario: Scenario) -> String? {
        guard scenario.targetBundleId.rawValue == HarnessTargets.testHostAlias, scenario.readback == .ax,
            scenario.expect.text != nil, scenario.layout?.rawValue == "com.apple.keylayout.ABC",
            scenario.setup.last(where: { $0.action == .setSecureInput })?.value != "on",
            !scenario.setup.contains(where: { $0.action == .testHook }),
            let field = scenario.setup.last(where: { $0.action == .focusField })?.value, plain.contains(field)
        else { return nil }
        return field
    }
}

func oracleText(_ scenario: Scenario, profiles: [AppProfile], targets: HarnessTargets, field: String) async throws
    -> (text: String, mode: TypingMode)
{
    let configuration = AppConfiguration.of(scenario, profiles: profiles)
    let settings = try await OracleSettings.load(configuration, targets: targets)
    var oracle = try ScenarioTextOracle(
        settings: settings, focused: field, passThroughFields: OracleFields.passThrough(configuration.profile),
        focusShortcuts: OracleFields.focusShortcuts)
    oracle.type(scenario.keys)
    return (oracle.text(of: field), oracle.mode)
}

@Suite struct ScenarioOracleTests {
    @Test func plainTestHostScenariosExpectWhatTheEngineProduces() async throws {
        let profiles = try repositoryProfiles()
        let targets = try repositoryTargets()
        var checked: [String] = []
        for scenario in try ScenarioRunner.load(directory: scenariosDirectory) {
            guard let field = OracleFields.checkable(scenario) else { continue }
            let (text, mode) = try await oracleText(scenario, profiles: profiles, targets: targets, field: field)
            #expect(text == scenario.expect.text, "\(scenario.id)")
            // Per-app memory would carry English mode into the next scenario of the same app (D12).
            #expect(mode == .vietnamese, "\(scenario.id) must end in Vietnamese mode")
            checked.append(scenario.id)
        }
        for id in [
            "testhost.commonWords.telex", "testhost.commonWords.vni", "testhost.englishRestore.samples",
            "testhost.backspace.punctuation", "testhost.fastTyping", "testhost.toggleHotkey",
            "testhost.perWindowRule.mainWindow", "testhost.perWindowRule.secondWindow", "testhost.macro.letters",
            "testhost.macro.punctuation", "testhost.restoreHotkey.twice", "testhost.password.noTransform",
            "testhost.privacyCanary.paste",
        ] {
            #expect(checked.contains(id), "\(id) is not checked by the oracle")
        }
    }

    /// The English-restore sample is typed in ASCII and must come back exactly as typed.
    @Test func englishRestoreSampleIsTheTypedText() throws {
        let byID = Dictionary(
            uniqueKeysWithValues: try ScenarioRunner.load(directory: scenariosDirectory).map { ($0.id, $0) })
        let sample = try #require(byID["testhost.englishRestore.samples"])
        let typed = sample.keys.compactMap(ScenarioTextOracle.character(for:)).map(String.init).joined()
        #expect(sample.expect.text == typed)
    }

    /// 15 keys per second at least (QA-R11): the fast profile's 30 ms interval is 33 keys per second.
    @Test func fastTypingIsAtLeastFifteenKeysPerSecond() throws {
        let byID = Dictionary(
            uniqueKeysWithValues: try ScenarioRunner.load(directory: scenariosDirectory).map { ($0.id, $0) })
        let fast = try #require(byID["testhost.fastTyping"])
        #expect(1_000_000_000 / fast.timing.intervalRange.upperBound >= 15)
    }
}

@Suite struct CommonWordsGoldenTests {
    static let count = 200

    /// Tokens of data/derived/attested-candidates.tsv in file order (most frequent first).
    static func frequencyList() throws -> [String] {
        let text = try String(
            contentsOf: repositoryRoot.appendingPathComponent("data/derived/attested-candidates.tsv"), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            line.split(separator: "\t").first.map(String.init)
        }
    }

    /// The first 200 tokens the engine keeps as typed in both methods (alone and followed by a space).
    static func commonWords(telex: SettingsState, vni: SettingsState) throws -> [String] {
        var chosen: [String] = []
        for word in try frequencyList() where chosen.count < count {
            guard let telexKeys = VietnameseKeys.telex(word), let vniKeys = VietnameseKeys.vni(word) else { continue }
            var telexOracle = try ScenarioTextOracle(settings: telex, focused: "f")
            telexOracle.type(telexKeys + ["space"])
            var vniOracle = try ScenarioTextOracle(settings: vni, focused: "f")
            vniOracle.type(vniKeys + ["space"])
            if telexOracle.text == word + " " && vniOracle.text == word + " " { chosen.append(word) }
        }
        return chosen
    }

    static func scenario(_ method: Scenario.Method, words: [String]) -> Scenario {
        let keys = words.enumerated().flatMap { index, word in
            (index == 0 ? [] : ["space"])
                + ((method == .telex ? VietnameseKeys.telex(word) : VietnameseKeys.vni(word)) ?? [])
        }
        return Scenario(
            id: "testhost.commonWords." + method.rawValue,
            targetBundleId: BundleKey(rawValue: HarnessTargets.testHostAlias)!,
            setup: [
                .init(action: .launch), .init(action: .setSecureInput, value: "off"),
                .init(action: .focusField, value: "testhost.native.textView"),
            ],
            keys: keys, timing: .normal, method: method, layout: InputSourceID(rawValue: "com.apple.keylayout.ABC"),
            expect: .init(text: words.joined(separator: " ")), readback: .ax)
    }

    @Test func commonWordsScenariosFollowTheFrequencyListAndTheEngine() async throws {
        let targets = try repositoryTargets()
        let telex = try await OracleSettings.load(AppConfiguration(method: .telex), targets: targets)
        let vni = try await OracleSettings.load(AppConfiguration(method: .vni), targets: targets)
        let words = try Self.commonWords(telex: telex, vni: vni)
        #expect(words.count == Self.count)
        for method in [Scenario.Method.telex, .vni] {
            let expected = Self.scenario(method, words: words)
            let file = scenariosDirectory.appendingPathComponent(expected.id + ".json")
            if ProcessInfo.processInfo.environment["UPDATE_SCENARIO_GOLDENS"] == "1" {
                try Data(ScenarioDocument.render(expected).utf8).write(to: file)
            }
            let committed = try ScenarioLoader().load(file: file)
            #expect(committed == expected, "\(expected.id): rerun with UPDATE_SCENARIO_GOLDENS=1")
            // The whole sentence, not only each word alone (an English run, L10, could restore later words).
            var oracle = try ScenarioTextOracle(settings: method == .telex ? telex : vni, focused: "f")
            oracle.type(committed.keys)
            #expect(oracle.text == committed.expect.text, "\(expected.id)")
        }
    }

    @Test func encoderSpellsTonesAndModifiersLast() {
        #expect(VietnameseKeys.telex("người") == ["n", "g", "u", "w", "o", "w", "i", "f"])
        #expect(VietnameseKeys.vni("người") == ["n", "g", "u", "7", "o", "7", "i", "2"])
        #expect(VietnameseKeys.telex("đường") == ["d", "d", "u", "w", "o", "w", "n", "g", "f"])
        #expect(VietnameseKeys.vni("việt") == ["v", "i", "e", "6", "t", "5"])
        #expect(VietnameseKeys.telex("ăn") == ["a", "w", "n"])
        #expect(VietnameseKeys.telex("Hà") == ["shift+h", "a", "f"])
        #expect(VietnameseKeys.telex("x2") == nil)
    }
}

/// Telex and VNI key scripts for a Vietnamese word: letters with their modifier keys in place (`aa`, `aw`, `ow`, `dd`;
/// VNI `a6`, `a8`, `o7`, `d9`) and the tone key at the end of the word, as people type it.
enum VietnameseKeys {
    private static let telexTones: [Unicode.Scalar: String] = [
        "\u{0301}": "s", "\u{0300}": "f", "\u{0309}": "r", "\u{0303}": "x", "\u{0323}": "j",
    ]
    private static let vniTones: [Unicode.Scalar: String] = [
        "\u{0301}": "1", "\u{0300}": "2", "\u{0309}": "3", "\u{0303}": "4", "\u{0323}": "5",
    ]
    /// Circumflex, breve, horn after the base letter.
    private static let telexMarks: [Unicode.Scalar: String] = ["\u{0302}": "", "\u{0306}": "w", "\u{031B}": "w"]
    private static let vniMarks: [Unicode.Scalar: String] = ["\u{0302}": "6", "\u{0306}": "8", "\u{031B}": "7"]

    static func telex(_ word: String) -> [String]? { keys(word, tones: telexTones, marks: telexMarks, stroke: "d") }
    static func vni(_ word: String) -> [String]? { keys(word, tones: vniTones, marks: vniMarks, stroke: "9") }

    private static func keys(
        _ word: String, tones: [Unicode.Scalar: String], marks: [Unicode.Scalar: String], stroke: String
    ) -> [String]? {
        var keys: [String] = []
        var tone: String?
        for character in word {
            let decomposed = String(character).decomposedStringWithCanonicalMapping.unicodeScalars
            guard let base = decomposed.first else { return nil }
            let lower = String(base).lowercased()
            if lower == "đ" {
                keys += [key("d", upper: base != "đ"), stroke]
                continue
            }
            guard lower.count == 1, ("a"..."z").contains(lower) else { return nil }
            keys.append(key(lower, upper: String(base) != lower))
            for mark in decomposed.dropFirst() {
                if let toneKey = tones[mark] {
                    tone = toneKey
                } else if let markKey = marks[mark] {
                    keys.append(markKey.isEmpty ? lower : markKey)  // Telex circumflex doubles the vowel
                } else {
                    return nil
                }
            }
        }
        return keys + (tone.map { [$0] } ?? [])
    }

    private static func key(_ letter: String, upper: Bool) -> String { upper ? "shift+" + letter : letter }
}

/// Renders a scenario in the repository's JSON style (two-space indentation, one array item per line).
enum ScenarioDocument {
    static func render(_ scenario: Scenario) -> String {
        var lines = ["{", #"  "$schema": "../schema/scenario.schema.json","#]
        lines.append("  \"id\": " + quoted(scenario.id) + ",")
        lines.append("  \"targetBundleId\": " + quoted(scenario.targetBundleId.rawValue) + ",")
        lines.append("  \"setup\": [")
        lines += scenario.setup.enumerated().map { index, step in
            let value = step.value.map { ",\n      \"value\": " + quoted($0) } ?? ""
            return "    {\n      \"action\": " + quoted(step.action.rawValue) + value + "\n    }"
                + (index < scenario.setup.count - 1 ? "," : "")
        }
        lines.append("  ],")
        lines.append("  \"keys\": [")
        lines += scenario.keys.enumerated().map { "    " + quoted($1) + ($0 < scenario.keys.count - 1 ? "," : "") }
        lines.append("  ],")
        lines.append("  \"timing\": " + quoted(scenario.timing.rawValue) + ",")
        lines.append("  \"method\": " + quoted(scenario.method.rawValue) + ",")
        if let layout = scenario.layout { lines.append("  \"layout\": " + quoted(layout.rawValue) + ",") }
        lines.append("  \"expect\": {\n    \"text\": " + quoted(scenario.expect.text ?? "") + "\n  },")
        lines.append("  \"readback\": " + quoted(scenario.readback.rawValue))
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }
}
