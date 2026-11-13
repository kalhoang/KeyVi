// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R905, D26: the "Record typing trace..." confirmation states the duration chosen in its picker, not the
// first choice (accessibility audit finding, docs/runbooks/accessibility-audit.md section 9), and the trace runs
// for the duration on screen when the user confirms.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct TypingTraceConfirmationTests {
    let bundle: TemporaryAppBundle

    init() throws {
        bundle = try TemporaryAppBundle(catalogs: [.diagnostics])
    }

    func localizer(_ language: InterfaceLanguage) -> Localizer {
        Localizer(language: language, appBundle: bundle.bundle)
    }

    @Test func choicesAreTheDefaultUpToTheMaximum_PLTR905() {
        #expect(TypingTraceConfirmation.durations == [60, 120, 180])
        let confirmation = TypingTraceConfirmation(appName: "Example")
        #expect(confirmation.selectedIndex == 0)
        #expect(confirmation.selectedSeconds == 60)
        #expect(confirmation.durationTitles(localizer(.vietnamese)) == ["60 giây", "120 giây", "180 giây"])
        #expect(confirmation.durationTitles(localizer(.english)) == ["60 seconds", "120 seconds", "180 seconds"])
    }

    @Test func messageFollowsThePicker() {
        var confirmation = TypingTraceConfirmation(appName: "Example")
        let vi = localizer(.vietnamese)
        let en = localizer(.english)
        #expect(confirmation.message(vi).hasPrefix("Example sẽ ghi lại các phím bạn gõ, kể cả chữ, trong 60 giây."))
        #expect(
            confirmation.message(en).hasPrefix("Example records the keys you type, including letters, for 60 seconds."))

        confirmation.select(index: 1)
        #expect(confirmation.selectedSeconds == 120)
        #expect(confirmation.message(vi).hasPrefix("Example sẽ ghi lại các phím bạn gõ, kể cả chữ, trong 120 giây."))
        #expect(
            confirmation.message(en).hasPrefix("Example records the keys you type, including letters, for 120 seconds.")
        )
        #expect(!confirmation.message(en).contains("60 seconds"))

        confirmation.select(index: 2)
        #expect(confirmation.selectedSeconds == 180)
        #expect(confirmation.message(en) == en.format(DiagnosticsText.traceConfirmMessage, "Example", 180))
    }

    @Test func noSelectionOrAnUnknownIndexKeepsTheChoiceOnScreen() {
        // NSPopUpButton reports -1 when nothing is selected.
        var confirmation = TypingTraceConfirmation(appName: "Example")
        confirmation.select(index: 2)
        confirmation.select(index: -1)
        #expect(confirmation.selectedSeconds == 180)
        confirmation.select(index: TypingTraceConfirmation.durations.count)
        #expect(confirmation.selectedSeconds == 180)
    }

    @Test func theAppNameIsAnArgument() {
        let confirmation = TypingTraceConfirmation(appName: "Renamed")
        #expect(confirmation.message(localizer(.english)).hasPrefix("Renamed records"))
    }
}
