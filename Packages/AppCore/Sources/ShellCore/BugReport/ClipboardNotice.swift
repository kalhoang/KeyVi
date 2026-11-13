// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R48 clipboard notices and the PLT-R1204 preview titles, composed from the buttons a surface actually shows:
// a button that is hidden (no repository, no support address, no suggestion yet) is never named, and a renamed
// button renames every sentence that mentions it.

public import InputHost

extension DiagnosticsCopy {
    /// How a list of button titles is joined: "A, B and C" or "A, B or C".
    public enum ListJoin: Sendable {
        case and, or

        var lastPair: DiagnosticsText {
            switch self {
            case .and: .buttonsAnd
            case .or: .buttonsOr
            }
        }
    }

    /// The visible titles of `controls`, in order, joined in the interface language; empty for no control.
    public static func buttonList(_ controls: [DiagnosticsControl], joinedBy join: ListJoin, _ localizer: Localizer)
        -> String
    {
        let titles = controls.map { localizer.string($0.labelKey) }
        guard let last = titles.last else { return "" }
        let leading = titles.dropLast()
        guard let first = leading.first else { return last }
        let series = leading.dropFirst().reduce(first) { localizer.format(DiagnosticsText.buttonsSeries, $0, $1) }
        return localizer.format(join.lastPair, series, last)
    }

    /// PRD-R48: shown before any clipboard write; names the buttons on screen that write to the clipboard.
    public static func clipboardNotice(buttons: [DiagnosticsControl], appName: String, _ localizer: Localizer)
        -> String
    {
        localizer.format(DiagnosticsText.clipboardNotice, buttonList(buttons, joinedBy: .or, localizer), appName)
    }

    /// In the Diagnostics window only "Copy report" writes to the clipboard (PLT-R1201).
    public static let windowClipboardControls: [DiagnosticsControl] = [.copyReport]

    /// The misbehaves panel's offers on screen that write to the clipboard, in display order (PLT-R1205).
    public static func clipboardControls(_ offers: [MisbehavesOffer]) -> [DiagnosticsControl] {
        offers.filter { $0 != .useForMe }.map(control)
    }

    /// The panel control (label and VoiceOver hint keys) of an offer (PRD-R66).
    public static func control(_ offer: MisbehavesOffer) -> DiagnosticsControl {
        switch offer {
        case .useForMe: .useForMe
        case .copySuggestion: .copySuggestion
        case .copyReport: .copyReport
        case .openGitHubIssue: .openGitHubIssue
        }
    }
}

extension BugReportSheet {
    /// The sheet's buttons on screen that write to the clipboard ("Copy report", and "Mở GitHub" with a
    /// repository), the ones the notice names (PRD-R48).
    public var clipboardControls: [DiagnosticsControl] { offered(ReportPreviewFormat.copiedBlock) }

    /// PRD-R48 notice of the sheet.
    public func clipboardNotice(appName: String, _ localizer: Localizer) -> String {
        DiagnosticsCopy.clipboardNotice(buttons: clipboardControls, appName: appName, localizer)
    }

    /// The preview segment title: the buttons on screen whose output `format` shows (PLT-R1204, PRD-R47 item 4).
    public func previewTitle(_ format: ReportPreviewFormat, _ localizer: Localizer) -> String {
        DiagnosticsCopy.buttonList(offered(format), joinedBy: .and, localizer)
    }

    private func offered(_ format: ReportPreviewFormat) -> [DiagnosticsControl] {
        format.paths.filter(actions.contains).map(\.control)
    }
}
