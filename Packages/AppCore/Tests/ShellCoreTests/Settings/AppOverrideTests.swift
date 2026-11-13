// SPDX-License-Identifier: GPL-3.0-or-later
//
// One "this app" user override per app (PLT-R540): the Apps pane's compatibility mode (PRD-R36) and the status
// line's "type here anyway" edit the same rule, because two bundle-only user overrides for one app tie and only
// the smaller id applies (PLT-R520 no merging, PLT-R521). Resolved through the real rule set.

import AppModel
import CompatRules
import Foundation
import InputHost
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

@Suite struct AppOverrideTests {
    let editor = BundleKey(rawValue: "com.example.Editor")!
    let date = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    func loaded() async -> SettingsCommands {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        return SettingsCommands(store: harness.store)
    }

    func resolve(_ state: SettingsState) throws -> ResolvedDecision {
        let (rules, rejected) = RulesLoader.decodeOverrides(state.ruleOverrides.map(\.rule))
        #expect(rejected.isEmpty)
        let set = try RuleSet(document: EmbeddedRules.minimal, overrides: rules, optedIn: [])
        return set.resolve(MatchContext(bundle: editor, appVersion: nil, macOS: LooseVersion("27.0")!, engine: .native))
    }

    func compatibilityMode(_ state: SettingsState) -> CompatibilityModeChoice? {
        AppsPaneModel.rows(appModes: state.appModes, overrides: state.ruleOverrides, matrix: nil, today: date)
            .first { $0.bundle == editor }?.compatibilityMode
    }

    @Test func typeHereAnywayKeepsTheCompatibilityMode_PLTR540() async throws {
        let commands = await loaded()
        _ = await commands.setCompatibility(.typeSlower, for: editor, at: date)
        let state = await commands.typeHereAnyway(for: editor, strategy: .backspaceReplace, at: date)
        #expect(state.ruleOverrides.count == 1)
        let decision = try resolve(state)
        #expect(decision.tieLoser == nil)
        #expect(decision.requireTextFocus == .never)
        #expect(decision.params.interEventDelayUs == 5_000)
        #expect(compatibilityMode(state) == .typeSlower)
    }

    @Test func aLaterCompatibilityModeKeepsTypeHereAnyway_PLTR540() async throws {
        let commands = await loaded()
        _ = await commands.typeHereAnyway(for: editor, strategy: .selectReplace, at: date)
        var state = await commands.setCompatibility(.typeSlower, for: editor, at: date)
        #expect(state.ruleOverrides.count == 1)
        var decision = try resolve(state)
        #expect(decision.tieLoser == nil)
        #expect(decision.requireTextFocus == .never)
        #expect(decision.strategy == .backspaceReplace && decision.params.interEventDelayUs == 5_000)
        #expect(compatibilityMode(state) == .typeSlower)

        // "Automatic" removes only the compatibility fields; "type here anyway" stays.
        state = await commands.setCompatibility(.automatic, for: editor, at: date)
        #expect(state.ruleOverrides.count == 1)
        decision = try resolve(state)
        #expect(decision.requireTextFocus == .never)
        #expect(decision.params.interEventDelayUs != 5_000)
        #expect((compatibilityMode(state) ?? .automatic) == .automatic)
    }

    @Test func typeHereAnywayAloneCapturesTheResolvedStrategy() async throws {
        let commands = await loaded()
        var state = await commands.typeHereAnyway(for: editor, strategy: .selectReplace, at: date)
        let decision = try resolve(state)
        #expect(decision.requireTextFocus == .never && decision.strategy == .selectReplace)
        // The captured strategy is not a compatibility mode the user chose.
        #expect(compatibilityMode(state) == nil)
        state = await commands.setCompatibility(.automatic, for: editor, at: date)
        #expect(try resolve(state).requireTextFocus == .never)
    }

    @Test func storedPairsFromEarlierVersionsAreFoldedIntoOne() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let compat = try #require(CompatibilityModeChoice.pasteText.overrideRule(for: editor, date: "2026-11-01"))
        let text = try #require(TextFocusOverride.rule(for: editor, strategy: .selectReplace, date: "2026-11-02"))
        await harness.store.addRuleOverride(StoredRuleOverride(createdAt: date, rule: compat))
        await harness.store.addRuleOverride(StoredRuleOverride(createdAt: date, rule: text))
        let commands = SettingsCommands(store: harness.store)
        let state = await commands.typeHereAnyway(for: editor, strategy: .selectReplace, at: date)
        #expect(state.ruleOverrides.count == 1)
        let decision = try resolve(state)
        #expect(decision.tieLoser == nil)
        #expect(decision.requireTextFocus == .never && decision.strategy == .paste)
    }
}
