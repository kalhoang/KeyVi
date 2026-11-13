// SPDX-License-Identifier: GPL-3.0-or-later
//
// Q13 (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md): the default tone
// style is the traditional one, `hòa` and `thủy`, and the D2 setting switches to `hoà` and `thuỷ`. Checked end to
// end: shipped defaults -> EngineBridge configuration -> what the engine types. Workstream W5-B.

import AppModel
import SettingsStore
import Testing
import VietnameseEngine

@testable import InputHost

/// Types `keys` into an empty field through a session of an engine built from `settings` and returns the field.
private func typed(_ keys: String, settings: EffectiveSettings) -> String {
    let engine = Engine(
        configuration: EngineBridge.configuration(for: settings, variant: .default), resources: .empty)
    var session = Session(engine: engine)
    var field: [Character] = []
    for key in keys {
        switch session.handle(.key(KeyInput(key))).action {
        case .passThrough:
            field.append(key)
        case .edit(let edit, let thenPassThrough):
            field.removeLast(min(edit.deleteCount, field.count))
            field.append(contentsOf: edit.insert)
            if thenPassThrough { field.append(key) }
        }
    }
    return String(field)
}

@Suite("Default tone style (Q13, D2)")
struct DefaultToneStyleTests {
    @Test func theShippedDefaultIsTraditional_Q13() {
        #expect(DefaultSettings.v1.tonePlacement == .traditional)
        #expect(UserSettings().resolved().tonePlacement == .traditional, "an unset D2 resolves to traditional")
        #expect(typed("hoaf thuyr ", settings: DefaultSettings.v1) == "hòa thủy ")
    }

    @Test func theSettingSwitchesToTheModernStyle_D2() {
        var modern = UserSettings()
        modern.tonePlacement = .set(.modern)
        #expect(typed("hoaf thuyr ", settings: modern.resolved()) == "hoà thuỷ ")
    }
}
