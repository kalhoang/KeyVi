// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R1119, PLT-R904A: replay rebuilds the engine from the recorded settings and focus, so its typo correction switch
// is the conjunction the host passes, taken over the recorded inputs, never a constant (plan of 19/11/2026, Task 3
// Step 3 and "The switch: three defaults, one rule"). A trace without D30 was written by engines that never corrected
// (1.0.x, and 1.1.0 while the host passes the switch off), so it replays with the switch off, as it ran.

import Testing
import VietnameseEngine

@testable import TraceScanCore

@Suite struct ReplayTypoCorrectionTests {
    /// The recorded settings of a 1.1.0 build with D30, D4 and D8 on.
    static let recorded = TraceBuilder.settings.merging(["typoCorrection": "true", "restoreHotkey": "key(escape)"]) {
        $1
    }

    static func focus(englishRestore: Bool, context: String = "general") -> TraceLine {
        var line = TraceLine(type: "focus", t: TraceBuilder.base)
        line.er = englishRestore
        line.ctx = context
        return line
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
