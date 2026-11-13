// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1105 automatic relaunch rule: never in the middle of a word, never while secure input is on, and never
// for a critical update, whose window Sparkle must show immediately (PRD-R54).

#if UPDATER_TESTS
import Testing

@Suite struct RelaunchGateTests {
    @Test(
        "PLT-R1105 decision table for ordinary updates",
        arguments: [
            (KeyboardIdleState(secondsSinceLastKey: 0, secureInputOn: false), RelaunchGate.Decision.installOnQuit),
            (KeyboardIdleState(secondsSinceLastKey: 45, secureInputOn: false), .installOnQuit),
            (KeyboardIdleState(secondsSinceLastKey: 59.9, secureInputOn: false), .installOnQuit),
            (KeyboardIdleState(secondsSinceLastKey: 60, secureInputOn: false), .installNow),
            (KeyboardIdleState(secondsSinceLastKey: 600, secureInputOn: false), .installNow),
            (KeyboardIdleState(secondsSinceLastKey: .infinity, secureInputOn: false), .installNow),
            (KeyboardIdleState(secondsSinceLastKey: 600, secureInputOn: true), .installOnQuit),
            (KeyboardIdleState(secondsSinceLastKey: .infinity, secureInputOn: true), .installOnQuit),
            (KeyboardIdleState(secondsSinceLastKey: .nan, secureInputOn: false), .installOnQuit),
            (KeyboardIdleState(secondsSinceLastKey: -5, secureInputOn: false), .installOnQuit),
        ])
    func decisionTable(state: KeyboardIdleState, expected: RelaunchGate.Decision) {
        #expect(RelaunchGate.decision(for: state, isCritical: false) == expected)
    }

    @Test(
        "PRD-R54: a critical update is always left to Sparkle, even with an idle keyboard",
        arguments: [
            KeyboardIdleState(secondsSinceLastKey: .infinity, secureInputOn: false),
            KeyboardIdleState(secondsSinceLastKey: 3600, secureInputOn: false),
            KeyboardIdleState(secondsSinceLastKey: 0, secureInputOn: true),
        ])
    func criticalIsNeverTakenOver(state: KeyboardIdleState) {
        #expect(RelaunchGate.decision(for: state, isCritical: true) == .installOnQuit)
    }

    @Test("PLT-R1105: the idle threshold is 60 s")
    func requiredIdle() {
        #expect(RelaunchGate.requiredIdle == .seconds(60))
    }
}
#endif
