// SPDX-License-Identifier: GPL-3.0-or-later
//
// Text the user is typing in the Settings window: the practice field and the two word-list add fields
// (PRD-R24, ENG-R860). It lives outside SettingsWindowModel so that a keystroke re-renders only the field that
// shows it; every pane observes the window model, and ObservableObject publishes whole-object changes (ADR 0315).
// The text stays in memory only (PLT-R901).

import Combine
import ShellCore

@MainActor
final class SettingsTextDrafts: ObservableObject {
    @Published var practiceText = ""
    @Published private var words: [UserWordList: String] = [:]

    subscript(list: UserWordList) -> String {
        get { words[list] ?? "" }
        set { words[list] = newValue }
    }
}
