// SPDX-License-Identifier: GPL-3.0-or-later
//
// The learned-words sheet of D28 (PRD-R78): the votes are read from the store's collision memory on the utility
// queue when the sheet opens and again after each edit, so the sheet always shows what the memory votes now. The
// rows and the edits are ShellCore's (`LearnedChoicesSheetState`, `SettingsEdit`), tested there.

import ShellCore

extension SettingsWindowModel {
    /// "Xem từ đã học...".
    func showLearnedChoices() {
        Task {
            learnedChoices = LearnedChoicesSheetState(votes: await commands.learnedChoices(), reading: learnedReading)
        }
    }

    func closeLearnedChoices() { learnedChoices = nil }

    /// One row: the row leaves at once, then the sheet shows the memory's votes after the edit.
    func forgetLearnedChoice(_ row: LearnedChoiceRow) {
        learnedChoices = learnedChoices?.removing(row)
        Task {
            apply(await commands.apply(row.forgetEdit))
            await reloadLearnedChoices()
        }
    }

    func requestClearLearnedChoices() { learnedChoices = learnedChoices?.confirmingClearAll(true) }

    func cancelClearLearnedChoices() { learnedChoices = learnedChoices?.confirmingClearAll(false) }

    /// "Xóa tất cả" after the confirmation: every entry and the file (PLT-R914).
    func confirmClearLearnedChoices() {
        learnedChoices = learnedChoices?.cleared
        Task {
            apply(await commands.apply(.clearLearnedChoices))
            await reloadLearnedChoices()
        }
    }

    /// The memory's votes now, while the sheet is open.
    private func reloadLearnedChoices() async {
        let votes = await commands.learnedChoices()
        learnedChoices = learnedChoices?.replacingVotes(votes, reading: learnedReading)
    }

    /// Vietnamese readings in the tone placement the user has now (D2), as the user sees the words typed.
    private var learnedReading: @Sendable (String) -> String {
        LearnedChoiceReading.vietnamese(tonePlacement: settings.tonePlacement)
    }
}
