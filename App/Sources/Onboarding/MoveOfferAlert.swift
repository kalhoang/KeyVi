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
        alert.addButton(withTitle: content.confirm)
        alert.addButton(withTitle: content.quit)
        return alert.runModal() == .alertFirstButtonReturn ? .move : .quit
    }
}
