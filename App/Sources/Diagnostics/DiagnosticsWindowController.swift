// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics window (PLT-R1201), "This app misbehaves" flow (PLT-R1205), bug report sheet (PRD-R47-R49),
// typing trace review (PLT-R905) and latency probe window (PLT-R810). Workstream W2-C.

import AppKit
import AppModel
import Diagnostics
import ShellCore

@MainActor
final class DiagnosticsWindowController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    init(language: InterfaceLanguageModel, report: @escaping @MainActor () -> DiagnosticsReport) { unimplemented() }
    func showReport() { unimplemented() }
    func startMisbehavesFlow(for bundle: BundleKey?) { unimplemented() }
    func startTypingTrace() { unimplemented() }
    func runLatencyProbe() { unimplemented() }
}

@MainActor
final class BugReportController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    /// Shows the exact redacted text before anything is copied or saved (PLT-R1204, PRD-R48).
    init(draft: BugReportDraft, report: DiagnosticsReport, language: InterfaceLanguageModel) { unimplemented() }
}
