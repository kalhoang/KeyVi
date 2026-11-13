// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Rows of the PRD-R43 table as `StatusLine` values. Every line states what happened, which app or component
// is involved and one concrete action (PRD-R43); no line carries typed content (PLT-R901).

internal import AppModel
internal import CompatRules
internal import Foundation

struct StatusLineBuilder {
    var appName: String
    var holderHintKey: String?
    var frontmostApp: FrontmostAppStatus?
    var onboardingCompleted: Bool

    func hostLine(for state: HostState) -> StatusLine? {
        switch state {
        case .noPermission, .failOpen(.permissionRevoked): permissionLine()
        case .failOpen(let reason): failOpenLine(reason)
        case .paused(let reason): pausedLine(reason)
        case .starting, .ready: nil
        }
    }

    /// PLT-R1009: the app runs on defaults in memory after a crash loop. The action opens the safe-mode choices
    /// (reset, use the saved settings, report), so they stay reachable from the menu at any time.
    func safeModeLine() -> StatusLine {
        line(.safeMode, [appName], action: .safeModeChoices, label: .actionSafeModeChoices)
    }

    func tapReenabledLine() -> StatusLine {
        line(.tapReenabled, [], action: .reportProblem, label: .actionReportProblem)
    }

    /// PRD-R43 "App in Known limitation list": the matrix note verbatim, with "Tìm hiểu thêm" when the entry
    /// links to an explanation.
    func knownLimitationLine() -> StatusLine? {
        guard let app = frontmostApp, app.matrixStatus == .knownLimitation else { return nil }
        let action: StatusLine.Action = app.learnMore.map { .learnMore($0) } ?? .none
        let label: StatusText? = app.learnMore == nil ? nil : .actionLearnMore
        if let note = app.limitationNote, !note.isEmpty {
            return line(.knownLimitationNote, [note], action: action, label: label)
        }
        return line(.knownLimitationGeneric, [app.displayName], action: action, label: label)
    }

    // MARK: - Host state rows

    private func permissionLine() -> StatusLine {
        // PRD-R41: before onboarding is complete the fix is screen 2 of onboarding.
        line(
            .noPermission, [appName], action: onboardingCompleted ? .grantPermission : .resumeOnboarding,
            label: .actionGrantPermission, hint: StatusText.builtInFallbackHint.rawValue)
    }

    private func failOpenLine(_ reason: FailOpenReason) -> StatusLine {
        switch reason {
        case .permissionRevoked: permissionLine()
        case .postingBroken: line(.postingBroken, [appName], action: .reportProblem, label: .actionReportProblem)
        case .tapUnavailable: line(.tapUnavailable, [appName], action: .reportProblem, label: .actionReportProblem)
        case .watchdog: line(.watchdog, [appName], action: .reportProblem, label: .actionReportProblem)
        case .callbackStuck:
            line(.callbackStuck, [appName], action: .reopenApp, label: .actionReopenApp, labelArguments: [appName])
        }
    }

    private func pausedLine(_ reason: PauseReason) -> StatusLine? {
        switch reason {
        case .secureInput(let holder): secureInputLine(holder)
        case .nonLatinInputSource(let name): line(.nonLatinSource, [name, appName], action: .none)
        case .builtInVietnameseSource: line(.builtInVietnamese, [appName], action: .none)
        case .noTextFocus: noTextFocusLine()
        case .userDisabled: line(.userDisabled, [appName], action: .none)
        // Expected pauses that are not problems: a password field, an ignored app (the icon says so), a
        // locked session, the guided test typing (its panel says so). PRD-R11 shows a status line only for a
        // problem.
        case .secureField, .passThroughRule, .sessionInactive, .diagnosticsTest: nil
        }
    }

    /// PRD-R43 secure input row, PLT-R396 holder kinds, PLT-R397 data-driven hint.
    private func secureInputLine(_ holder: SecureInputHolder?) -> StatusLine {
        let hint = secureInputHint(holder)
        guard let holder else {
            return line(
                .secureInputUnknownHolder, [], action: .secureInputHelp,
                label: .actionSecureInputHelpUnknownHolder, hint: hint)
        }
        switch holder.kind {
        case .loginWindow, .exitedProcess:
            return line(.secureInputStaleHolder, [], action: .secureInputHelp, label: .actionSecureInputHelp)
        case .application, .process:
            guard let name = holder.displayName, !name.isEmpty else {
                return line(
                    .secureInputUnknownHolder, [], action: .secureInputHelp,
                    label: .actionSecureInputHelpUnknownHolder, hint: hint)
            }
            if holder.kind == .application {
                return line(
                    .secureInputHolder, [name], action: .showHolderApp(pid: holder.pid), label: .actionShowHolder,
                    labelArguments: [name], hint: hint)
            }
            return line(.secureInputHolder, [name], action: .secureInputHelp, label: .actionSecureInputHelp, hint: hint)
        }
    }

    private func secureInputHint(_ holder: SecureInputHolder?) -> String? {
        guard let key = holderHintKey ?? holder?.hintKey, StatusText.knownSecureInputHintKeys.contains(key) else {
            return nil
        }
        return StatusText.secureInputHintPrefix + key
    }

    /// "paused: no text field detected" with the one-click `requireTextFocus: never` override (PLT-R540).
    private func noTextFocusLine() -> StatusLine {
        guard let app = frontmostApp else { return line(.noTextFocusUnknownApp, [appName], action: .none) }
        return line(
            .noTextFocus, [appName, app.displayName], action: .overrideTextFocus(bundle: app.bundle),
            label: .actionOverrideTextFocus, labelArguments: [app.displayName])
    }

    private func line(
        _ key: StatusText, _ arguments: [String], action: StatusLine.Action, label: StatusText? = nil,
        labelArguments: [String] = [], hint: String? = nil
    ) -> StatusLine {
        StatusLine(
            key: key.rawValue, arguments: arguments, action: action, hintKey: hint, actionLabelKey: label?.rawValue,
            actionLabelArguments: labelArguments)
    }
}

extension StatusLine {
    /// Rendered message in the selected language (status line arguments are app and source names only).
    public func message(_ localizer: Localizer) -> String {
        localizer.format(key, table: .status, arguments: arguments)
    }

    public func actionLabel(_ localizer: Localizer) -> String? {
        actionLabelKey.map { localizer.format($0, table: .status, arguments: actionLabelArguments) }
    }

    public func hint(_ localizer: Localizer) -> String? {
        hintKey.map { localizer.string($0, table: .status) }
    }

    /// Menu rendering helper: one sentence per line so a long status line does not make the menu very wide.
    public static func sentences(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in text {
            if character == " ", let last = current.last, ".?!".contains(last) {
                lines.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
