// SPDX-License-Identifier: GPL-3.0-or-later
//
// The composition root's own modal notices: safe mode (PLT-R1009), a failed move to Applications (PLT-R710) and
// the once-per-launch conflict warning (PLT-R399). None of them is shown by the integration hooks test build.
// Copy lives in the `Composition` String Catalog, read through the shared `Localizer` of the selected interface
// language (ADR 0310; keys in ShellCore's `CompositionText`); the app name is always a format argument. The
// conflict warning reuses the onboarding screen 5 copy from spec/03-product.md. Workstream W2-A.

import AppKit
import AppModel
import InputHost
import ShellCore

@MainActor
enum CompositionAlerts {
    enum SafeModeChoice { case reset, exit, report, later }
    enum ConflictChoice { case dismiss, help, openKeyboard }

    /// PLT-R1009: "offer reset or report". Shown at launch in safe mode and from the menu's report item.
    static func safeMode(appName: String, localizer: Localizer) -> SafeModeChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localizer.format(CompositionText.safeModeTitle, appName)
        alert.informativeText = localizer.format(CompositionText.safeModeBody, appName)
        let buttons: [(CompositionText, CompositionText)] = [
            (.safeModeReset, .safeModeResetHint), (.safeModeExit, .safeModeExitHint),
            (.safeModeReport, .safeModeReportHint), (.safeModeLater, .safeModeLaterHint),
        ]
        for (title, hint) in buttons {
            addButton(alert, title: localizer.string(title), hint: localizer.string(hint))
        }
        switch run(alert) {
        case .alertFirstButtonReturn: return .reset
        case .alertSecondButtonReturn: return .exit
        case .alertThirdButtonReturn: return .report
        default: return .later
        }
    }

    /// PLT-R710: the move failed, so the app quits rather than asking for permissions from here.
    static func moveFailed(appName: String, localizer: Localizer) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localizer.format(CompositionText.moveFailedTitle, appName)
        alert.informativeText = localizer.format(CompositionText.moveFailedBody, appName)
        addButton(
            alert, title: localizer.string(CompositionText.moveFailedQuit),
            hint: localizer.string(CompositionText.moveFailedQuitHint))
        run(alert)
    }

    /// PLT-R399: once per launch, plain explanation, never touches the other app. The dismiss button comes
    /// first so Return closes the notice; the help page is offered for a running app and Keyboard settings for
    /// a built-in Vietnamese source (PRD-R40 screen 5, PRD-R43: one concrete action each).
    static func conflicts(
        _ conflicts: [ConflictingInput], appName: String, keyboardPane: String, localizer: Localizer
    ) -> ConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localizer.string(OnboardingText.conflictsTitle)
        alert.informativeText = conflicts.map { body($0, appName: appName, localizer: localizer) }
            .joined(separator: "\n\n")
        var choices: [ConflictChoice] = [.dismiss]
        addButton(
            alert, title: localizer.string(CompositionText.conflictsDismiss),
            hint: localizer.string(CompositionText.conflictsDismissHint))
        if let helpName = conflicts.compactMap(\.runningAppName).first {
            choices.append(.help)
            addButton(
                alert, title: localizer.format(OnboardingText.conflictsHowToQuit, helpName),
                hint: localizer.string(CompositionText.conflictsHelpHint))
        }
        if conflicts.contains(where: \.isBuiltInSource) {
            choices.append(.openKeyboard)
            addButton(
                alert, title: localizer.format(OnboardingText.conflictsOpenKeyboard, keyboardPane),
                hint: localizer.string(CompositionText.conflictsOpenKeyboardHint))
        }
        let index = run(alert).rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .dismiss
    }

    private static func body(_ conflict: ConflictingInput, appName: String, localizer: Localizer) -> String {
        switch conflict {
        case .runningApp(_, let name): localizer.format(OnboardingText.conflictsBody, name)
        case .builtInVietnameseSource: localizer.format(OnboardingText.conflictsBuiltIn, appName)
        }
    }

    /// An agent app's alert opened from the launch path may otherwise appear behind the frontmost app without
    /// keyboard focus (PLT-R1009, PLT-R399: the user must see the explanation).
    ///
    /// The self-hosted runner's test build (INTEGRATION_HOOKS, ADR 0502) never opens one: a modal notice would take
    /// the keys a scenario types and stall the harness. It answers `.abort`, which every caller treats as its
    /// choice that changes nothing (later, dismiss); the episode itself is still logged by the caller's path.
    @discardableResult
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        #if INTEGRATION_HOOKS
        return .abort
        #else
        NSApp.bringToFront()
        return alert.runModal()
        #endif
    }

    /// PRD-R66: an alert button is labelled by its title; the hint carries what it does.
    private static func addButton(_ alert: NSAlert, title: String, hint: String) {
        let button = alert.addButton(withTitle: title)
        button.setAccessibilityHelp(hint)
    }
}

extension ConflictingInput {
    var runningAppName: String? {
        if case .runningApp(_, let name) = self { return name }
        return nil
    }

    var isBuiltInSource: Bool {
        if case .builtInVietnameseSource = self { return true }
        return false
    }
}
