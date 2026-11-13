// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R710 move offer, shown before any permission request when `AppLocationCheck.evaluate` says `mustMove`.
// The composition root (W2-A) performs the move and relaunch after "Chuyển và mở lại"; this type only asks.

import AppKit
import ShellCore

@MainActor
enum MoveOfferAlert {
    enum Choice: Sendable, Hashable { case move, quit }

    /// Modal because nothing else may happen first: permissions must not be requested from this location.
    static func ask(reason: AppLocationCheck.Reason, appName: String, language: InterfaceLanguageModel) -> Choice {
        let content = MoveOfferContent(localizer: language.localizer, appName: appName, reason: reason)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = content.title
        alert.informativeText = content.body
        let localizer = language.localizer
        // PRD-R66: alert buttons are labelled by their titles; the hints come from the Onboarding table.
        for (title, control) in [(content.confirm, OnboardingControl.moveConfirm), (content.quit, .moveQuit)] {
            let button = alert.addButton(withTitle: title)
            button.setAccessibilityHelp(localizer.string(control.accessibilityHintKey, table: .onboarding))
        }
        return alert.runModal() == .alertFirstButtonReturn ? .move : .quit
    }
}
