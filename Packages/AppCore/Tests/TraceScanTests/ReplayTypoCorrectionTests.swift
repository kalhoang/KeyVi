// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R1119, PLT-R904A: replay rebuilds the engine from the recorded settings and focus, so its typo correction switch
// is the conjunction the host passes, taken over the recorded inputs, never a constant (plan of 19/11/2026, Task 3
// Step 3 and "The switch: three defaults, one rule"). A trace without D30 was written by engines that never corrected
// (1.0.x, and 1.1.0 while the host passes the switch off), so it replays with the switch off, as it ran. Since the
// host wires the switch (Task 24) the recorder writes D30 in the settings line and the rule's `restoreHotkey` in the
// focus line (`rhk`), and replay agrees with the host mapping for every combination of the five inputs.

import Testing
import VietnameseEngine

@testable import TraceScanCore

#if DEV_RECORDER
import AppModel
import CompatRules
import Foundation
import InputHost
import RealtimeSupport
import SettingsStore
import ShellCore

@testable import Diagnostics
#endif

@Suite struct ReplayTypoCorrectionTests {
    /// The recorded settings of a 1.1.0 build with D30, D4 and D8 on.
    static let recorded = TraceBuilder.settings.merging(["typoCorrection": "true", "restoreHotkey": "key(escape)"]) {
        $1
    }

    static func focus(englishRestore: Bool, restoreHotkey: Bool? = nil, context: String = "general") -> TraceLine {
        var line = TraceLine(type: "focus", t: TraceBuilder.base)
        line.er = englishRestore
        line.rhk = restoreHotkey
        line.ctx = context
        return line
    }

    /// ENG-R1119: a rule that turns the restore key off (Spotlight, the overlay panels) recorded `rhk: false`; its
    /// segments replay without the correction, as the host ran them. A focus line without `rhk` (written before the
    /// field existed, when no engine corrected) leaves the decision to the other inputs, like `er`.
    @Test func aRuleWithoutTheRestoreKeyReplaysWithTheSwitchOff() {
        let panel = Self.focus(englishRestore: true, restoreHotkey: false)
        #expect(!ReplayEngineFactory.typoCorrection(settings: Self.recorded, focus: panel))
        let factory = ReplayEngineFactory(resources: .empty)
        let engine = factory.engine(settings: Self.recorded, focus: panel)?.configuration
        #expect(engine?.typoCorrection == false && engine?.autoRestore == true)
        let editor = Self.focus(englishRestore: true, restoreHotkey: true)
        #expect(ReplayEngineFactory.typoCorrection(settings: Self.recorded, focus: editor))
        #expect(ReplayEngineFactory.typoCorrection(settings: Self.recorded, focus: Self.focus(englishRestore: true)))
    }

    @Test func aTraceWithoutD30ReplaysWithTheSwitchOff() {
        let factory = ReplayEngineFactory(resources: .empty)
        let engine = factory.engine(settings: TraceBuilder.settings, focus: Self.focus(englishRestore: true))
        #expect(engine?.configuration.typoCorrection == false)
        #expect(!ReplayEngineFactory.typoCorrection(settings: TraceBuilder.settings, focus: nil))
    }

    @Test func theSwitchIsD30AndD4AndTheRuleAndTheRestoreKey_ENGR1119() {
        let on = Self.focus(englishRestore: true)
        #expect(ReplayEngineFactory.typoCorrection(settings: Self.recorded, focus: on))
        // Each input alone turns it off.
        func with(_ key: String, _ value: String) -> [String: String] { Self.recorded.merging([key: value]) { $1 } }
        #expect(!ReplayEngineFactory.typoCorrection(settings: with("typoCorrection", "false"), focus: on))  // D30
        #expect(!ReplayEngineFactory.typoCorrection(settings: with("englishRestore", "false"), focus: on))  // D4
        #expect(!ReplayEngineFactory.typoCorrection(settings: with("restoreHotkey", "none"), focus: on))  // D8
        #expect(!ReplayEngineFactory.typoCorrection(settings: Self.recorded, focus: Self.focus(englishRestore: false)))
        // The engine built for the segment carries the derived value, next to the derived auto restore.
        let factory = ReplayEngineFactory(resources: .empty)
        #expect(factory.engine(settings: Self.recorded, focus: on)?.configuration.typoCorrection == true)
        let off = factory.engine(settings: with("restoreHotkey", "none"), focus: on)?.configuration
        #expect(off?.typoCorrection == false && off?.autoRestore == true)
    }
}

#if DEV_RECORDER
extension ReplayTypoCorrectionTests {
    /// Replay follows the host mapping input for input (plan, "The switch: three defaults, one rule"): for each of the
    /// 2^5 combinations of D30, D4, the rule's `englishRestore`, the rule's `restoreHotkey` and D8, the settings are
    /// written by the recorder's settings snapshot and the focus by the recorder's focus record (from the decision the
    /// host maps from the rule), read back as the scanner reads trace lines, and replay's switch equals the switch
    /// `EngineBridge.configuration(for:variant:)` gives the live engine.
    @Test(arguments: 0..<32)
    func replayAgreesWithTheHostForEveryCombination(_ bits: Int) throws {
        let (d30, d4, rule, ruleKey, d8) = (bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0, bits & 16 != 0)
        var user = UserSettings()
        user.typoCorrection = .set(d30)
        user.englishRestore = .set(d4)
        user.restoreHotkey = .set(d8 ? .key(.escape) : nil)
        let state = SettingsState(user: user)
        let decision = HostDecisionMapper.map(
            Self.resolved(englishRestore: rule, restoreHotkey: ruleKey), engine: .native, optedIntoPaste: false)
        let host = EngineBridge.configuration(for: state.effective, variant: decision.variant).typoCorrection

        let settings = try Self.read(.settings(DevRecorderSettings.snapshot(state), at: .zero))
        let snapshot = FocusSnapshot(
            generation: .initial, app: nil, field: .unknown, decision: decision, mode: .vietnamese,
            modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero, pause: nil)
        let focus = try Self.read(.focus(DevFocusRecord(snapshot, at: .zero)))
        #expect(settings.s?["typoCorrection"] == String(d30))
        #expect(focus.rhk == ruleKey)
        #expect(ReplayEngineFactory.typoCorrection(settings: settings.s ?? [:], focus: focus) == host)
        #expect(host == (d30 && d4 && rule && ruleKey && d8))
    }

    /// A rule decision with the two switches of the variant under test.
    private static func resolved(englishRestore: Bool, restoreHotkey: Bool) -> ResolvedDecision {
        ResolvedDecision(
            rule: RuleID(rawValue: "test.rule"), source: .shipped, specificity: 1, strategy: .backspaceReplace,
            params: .defaults, fallback: [], defaultMode: .inherit, requireTextFocus: .never, verifyReentry: .never,
            axEnable: .none, overlay: false, requiresUserOptIn: false, engineContext: .general,
            features: ResolvedFeatures(
                autoCapitalize: false, macros: true, englishRestore: englishRestore, restoreHotkey: restoreHotkey))
    }

    /// The line the recorder writes for `record`, read as the scanner reads it.
    private static func read(_ record: DevTraceRecord) throws -> TraceLine {
        let data = DevTraceFiles.encode([DevTraceLine(record, t: TraceBuilder.base)])
        let line = try #require(data.split(separator: 0x0A).first)
        return try JSONDecoder().decode(TraceLine.self, from: Data(line))
    }
}
#endif
