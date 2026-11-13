// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The composition root's own modal notices: safe mode (PLT-R1009), a failed move to Applications (PLT-R710) and
// the once-per-launch conflict warning (PLT-R399). Copy lives in the `Composition` String Catalog, looked up in
// the selected interface language's lproj (ADR 0310); the app name is always a format argument. The conflict
// warning reuses the onboarding screen 5 copy from spec/03-product.md. Workstream W2-A.

import AppKit
import AppModel
import InputHost
import ShellCore

/// Keys of `App/Resources/Localization/Composition.xcstrings`.
enum CompositionText: String {
    case safeModeTitle = "safeMode.title"
    case safeModeBody = "safeMode.body"
    case safeModeReset = "safeMode.reset"
    case safeModeResetHint = "safeMode.reset.hint"
    case safeModeExit = "safeMode.exit"
    case safeModeExitHint = "safeMode.exit.hint"
    case safeModeReport = "safeMode.report"
    case safeModeReportHint = "safeMode.report.hint"
    case safeModeLater = "safeMode.later"
    case safeModeLaterHint = "safeMode.later.hint"
    case moveFailedTitle = "move.failed.title"
    case moveFailedBody = "move.failed.body"
    case moveFailedQuit = "move.failed.quit"
    case moveFailedQuitHint = "move.failed.quit.hint"
    case conflictsHelpHint = "conflicts.help.hint"
    case conflictsDismiss = "conflicts.dismiss"
    case conflictsDismissHint = "conflicts.dismiss.hint"
    case conflictsOpenKeyboardHint = "conflicts.openKeyboard.hint"

    static let table = "Composition"
}

/// Per-language lookup of the `Composition` table with the Vietnamese fallback, like ShellCore's `Localizer`.
struct CompositionStrings {
    let language: InterfaceLanguage
    let appBundle: Bundle

    func string(_ key: CompositionText) -> String {
        for code in [language.rawValue, InterfaceLanguage.vietnamese.rawValue] {
            guard let path = appBundle.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path)
            else { continue }
            let value = bundle.localizedString(forKey: key.rawValue, value: Self.missing, table: CompositionText.table)
            if value != Self.missing { return value }
        }
        return key.rawValue
    }

    func format(_ key: CompositionText, _ arguments: any CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    private static let missing = "\u{1}missing\u{1}"
}

@MainActor
enum CompositionAlerts {
    enum SafeModeChoice { case reset, exit, report, later }
    enum ConflictChoice { case dismiss, help, openKeyboard }

    /// PLT-R1009: "offer reset or report". Shown at launch in safe mode and from the menu's report item.
    static func safeMode(appName: String, strings: CompositionStrings) -> SafeModeChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.format(.safeModeTitle, appName)
        alert.informativeText = strings.format(.safeModeBody, appName)
        let buttons: [(CompositionText, CompositionText)] = [
            (.safeModeReset, .safeModeResetHint), (.safeModeExit, .safeModeExitHint),
            (.safeModeReport, .safeModeReportHint), (.safeModeLater, .safeModeLaterHint),
        ]
        for (title, hint) in buttons { addButton(alert, title: strings.string(title), hint: strings.string(hint)) }
        switch run(alert) {
        case .alertFirstButtonReturn: return .reset
        case .alertSecondButtonReturn: return .exit
        case .alertThirdButtonReturn: return .report
        default: return .later
        }
    }

    /// PLT-R710: the move failed, so the app quits rather than asking for permissions from here.
    static func moveFailed(appName: String, strings: CompositionStrings) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.format(.moveFailedTitle, appName)
        alert.informativeText = strings.format(.moveFailedBody, appName)
        addButton(alert, title: strings.string(.moveFailedQuit), hint: strings.string(.moveFailedQuitHint))
        run(alert)
    }

    /// PLT-R399: once per launch, plain explanation, never touches the other app. The dismiss button comes
    /// first so Return closes the notice; the help page is offered for a running app and Keyboard settings for
    /// a built-in Vietnamese source (PRD-R40 screen 5, PRD-R43: one concrete action each).
    static func conflicts(
        _ conflicts: [ConflictingInput], appName: String, keyboardPane: String, localizer: Localizer,
        strings: CompositionStrings
    ) -> ConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localizer.string(OnboardingText.conflictsTitle)
        alert.informativeText = conflicts.map { body($0, appName: appName, localizer: localizer) }
            .joined(separator: "\n\n")
        var choices: [ConflictChoice] = [.dismiss]
        addButton(alert, title: strings.string(.conflictsDismiss), hint: strings.string(.conflictsDismissHint))
        if let helpName = conflicts.compactMap(\.runningAppName).first {
            choices.append(.help)
            addButton(
                alert, title: localizer.format(OnboardingText.conflictsHowToQuit, helpName),
                hint: strings.string(.conflictsHelpHint))
        }
        if conflicts.contains(where: \.isBuiltInSource) {
            choices.append(.openKeyboard)
            addButton(
                alert, title: localizer.format(OnboardingText.conflictsOpenKeyboard, keyboardPane),
                hint: strings.string(.conflictsOpenKeyboardHint))
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
    @discardableResult
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
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
