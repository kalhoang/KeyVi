// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The "Update failed" state of PRD-R43: what happened, which version keeps running, and two concrete actions
// ("Thử lại", "Tải từ trang web"). Shown in place of Sparkle's generic error alert, in the interface language
// (D18), only when the user already knew an update was in progress (Sparkle's `showUpdaterError` contract).

import AppKit
import AppModel
import ShellCore

/// What the user chose in the update-failed alert.
enum UpdateFailureChoice: Sendable, Hashable {
    case retry, download, close
}

/// Copy and targets of the alert, resolved for one language. Pure, so it is tested without AppKit.
struct UpdateFailureContent: Sendable, Hashable {
    struct Button: Sendable, Hashable {
        var control: UpdateFailureControl
        var title: String
        var accessibilityLabel: String
        var accessibilityHint: String
    }

    var title: String
    var message: String
    /// Return activates the first button (retry); Escape the last one (close).
    var buttons: [Button]
    /// The website's download page in the interface language (site route "download", `site/lib/routes.mjs`).
    var downloadURL: URL

    /// Download page paths per language, mirroring the site's `download` route.
    static let downloadPaths: [InterfaceLanguage: String] = [.vietnamese: "/tai-ve/", .english: "/en/download/"]

    init(localizer: Localizer, appName: String, version: String, siteHost: String) {
        title = localizer.string(UpdatesText.failedTitle)
        message = localizer.format(UpdatesText.failedBody, version)
        buttons = UpdateFailureControl.allCases.map { control in
            Button(
                control: control, title: localizer.string(control.title),
                accessibilityLabel: localizer.string(control.accessibilityLabelKey, table: .updates),
                accessibilityHint: localizer.format(control.accessibilityHintKey, table: .updates, appName))
        }
        downloadURL = Self.downloadPage(siteHost: siteHost, language: localizer.language)
    }

    static func downloadPage(siteHost: String, language: InterfaceLanguage) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = downloadPaths[language] ?? "/"
        guard let url = components.url else { preconditionFailure("AppSiteHost is not a valid host") }
        return url
    }
}

/// Shows the alert and returns the choice. The test double records the content instead.
@MainActor
protocol UpdateFailurePresenting: AnyObject {
    func present(_ content: UpdateFailureContent) -> UpdateFailureChoice
}

/// Production presenter: a modal `NSAlert`, like Sparkle's own error alert. Its buttons are standard push buttons,
/// so they are keyboard reachable with a focus ring; nothing relies on colour and nothing animates beyond the
/// system's own window appearance, which follows Reduce Motion (PRD-R67).
@MainActor
final class AlertUpdateFailurePresenter: UpdateFailurePresenting {
    nonisolated static let escapeKey = "\u{1b}"

    func present(_ content: UpdateFailureContent) -> UpdateFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.message
        for button in content.buttons {
            let control = alert.addButton(withTitle: button.title)
            control.setAccessibilityLabel(button.accessibilityLabel)
            control.setAccessibilityHelp(button.accessibilityHint)
            if button.control == .close { control.keyEquivalent = Self.escapeKey }
        }
        // A menu-bar app (LSUIElement) is never active on its own; bring the alert in front of the user.
        NSApp.activate()
        return Self.choice(for: alert.runModal(), buttons: content.buttons)
    }

    /// `NSAlert` numbers buttons from `alertFirstButtonReturn` in the order they were added.
    nonisolated static func choice(for response: NSApplication.ModalResponse, buttons: [UpdateFailureContent.Button])
        -> UpdateFailureChoice
    {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return .close }
        switch buttons[index].control {
        case .retry: return .retry
        case .download: return .download
        case .close: return .close
        }
    }
}
