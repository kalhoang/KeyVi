// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Hỗ trợ / Support" (PRD-R24; Pa, 15/11/2026): report a problem and diagnostics (D26), help on the website and by
// email, settings export, import and the global reset (PRD-R26, PLT-R1010), and the privacy summary, each in its own
// grouped section.

import AppModel
import ShellCore
import SwiftUI

struct SupportPaneView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        SettingsPaneForm {
            ReportSection(model: model)
            HelpSection(model: model)
            SettingsFilesSection(model: model)
            PrivacySection(model: model)
        }
    }
}

/// "Báo lỗi và chẩn đoán": the explanation, then "Báo lỗi..." and "Chẩn đoán...".
struct ReportSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.string(SupportText.reportTitle)) {
            VStack(alignment: .leading, spacing: 8) {
                RowLabel(title: localizer.string(SupportText.diagnosticsExplanation))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(action: { model.reportProblem() }) {
                        Text(verbatim: localizer.string(SupportText.reportProblem))
                    }
                    .settingsAccessibility(SupportControl.reportProblem, localizer)
                    Button(action: model.openDiagnostics) { Text(verbatim: localizer.string(SupportText.diagnostics)) }
                        .settingsAccessibility(SupportControl.diagnostics, localizer)
                }
            }
        }
    }
}

/// "Trợ giúp": the website's support page and, when the brand has a support address, an email.
struct HelpSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.string(SupportText.helpTitle)) {
            SettingsFormRow(
                title: localizer.string(SupportText.helpWebsiteTitle),
                explanation: localizer.string(SupportText.helpWebsiteExplanation)
            ) {
                Button(action: model.openSupportPage) { Text(verbatim: localizer.string(SupportText.helpWebsiteOpen)) }
                    .settingsAccessibility(SupportControl.helpWebsite, localizer)
            }
            if let email = model.brand.supportEmail, let url = AboutSupportContent.mailURL(brand: model.brand) {
                SettingsFormRow(
                    title: localizer.string(SupportText.helpEmailTitle),
                    explanation: localizer.format(SupportText.helpEmailExplanation, email)
                ) {
                    Button(action: { model.open(url) }) { Text(verbatim: localizer.string(SupportText.helpEmailOpen)) }
                        .settingsAccessibility(SupportControl.helpEmail, localizer)
                }
            }
        }
    }
}

/// PRD-R24 and PLT-R1010: export, import and the global reset (PRD-R26).
struct SettingsFilesSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.string(SupportText.settingsTitle)) {
            VStack(alignment: .leading, spacing: 8) {
                RowLabel(title: localizer.string(SupportText.settingsExplanation))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(action: model.requestExport) {
                        Text(verbatim: localizer.string(SupportText.exportSettings))
                    }
                    .settingsAccessibility(SupportControl.exportSettings, localizer)
                    Button(action: model.chooseImportFile) {
                        Text(verbatim: localizer.string(SupportText.importSettings))
                    }
                    .settingsAccessibility(SupportControl.importSettings, localizer)
                    Button(action: { model.requestReset(.all) }) {
                        Text(verbatim: localizer.string(SupportText.resetAll))
                    }
                    .settingsAccessibility(SupportControl.resetAll, localizer)
                }
            }
        }
    }
}

struct PrivacySection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.string(SupportText.privacyTitle)) {
            RowLabel(title: localizer.format(SupportText.privacyBody, model.markedName))
        }
    }
}
