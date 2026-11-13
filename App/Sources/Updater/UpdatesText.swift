// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed keys of the `Updates` String Catalog (ADR 0310, PRD-R62). The updater refers to copy only through these
// enums, so the catalog test can check that every key exists in vi and en with matching arguments and that the
// catalog holds no dead copy. The app name and the version are always format arguments, never part of the copy.

import ShellCore

/// `Updates` table keys used by the Sparkle wrapper.
enum UpdatesText: String, LocalizationKey {
    static var table: StringTable { .updates }

    /// PRD-R43 "Update failed" row, first sentence of the draft.
    case failedTitle = "updates.failed.title"
    /// PRD-R43 "Update failed" row, second sentence of the draft. `%@` is the running version.
    case failedBody = "updates.failed.body"
    case retry = "updates.failed.retry"
    case download = "updates.failed.download"
    case close = "updates.failed.close"
    /// PRD-R53: shown by the About & Support pane right after the user leaves Beta. `%@` is the app name.
    case stableNoDowngrade = "updates.channel.stableNoDowngrade"
}

/// Every control the updater adds: the buttons of the update-failed alert, each with a VoiceOver label and hint
/// (PRD-R66). The label and the button title are the same words; the hint says what happens.
enum UpdateFailureControl: String, CaseIterable, Sendable {
    case retry, download, close

    var title: UpdatesText {
        switch self {
        case .retry: .retry
        case .download: .download
        case .close: .close
        }
    }

    var accessibilityLabelKey: String { "updates.control.\(rawValue).accessibilityLabel" }
    /// The download hint takes the app name as its argument; the other two take none.
    var accessibilityHintKey: String { "updates.control.\(rawValue).accessibilityHint" }
}
