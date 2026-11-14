// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Giới thiệu & Hỗ trợ / About & Support" (PRD-R24): version and channel, update controls (D19-D21, PRD-R53),
// diagnostics (D26), report a problem, export, import and reset, privacy summary, licences and acknowledgements
// (the app's own GPL-3.0-or-later licence of ADR 0006, ENG-R811, Sparkle), and the donation block (PRD-R57 to
// PRD-R59, the bundled bank VietQR code of Pa's decision S8), each in its own grouped section (W8-D).

import AppKit
import AppModel
import ShellCore
import SwiftUI
import VietnameseEngine
import VietnameseEngineData

struct AboutSupportPaneView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsPaneForm {
            SettingsGroup { AboutHeader(model: model) }
            ForEach(SettingsCatalog.sections(in: .aboutSupport), id: \.self) { section in
                SettingsGroup(header: section.header.map(localizer.string)) {
                    ForEach(section.rows, id: \.self) { row in SettingsSectionRow(model: model, items: row) }
                    CheckForUpdatesRow(model: model)
                }
            }
            HelpSection(model: model)
            SettingsFilesSection(model: model)
            PrivacySection(model: model)
            DonationSection(model: model)
        }
    }
}

/// The app's icon, name, version and channel.
struct AboutHeader: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: model.appName).font(.title2.weight(.semibold))
                Text(verbatim: AboutSupportContent.versionLine(brand: model.brand, localizer: model.localizer))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// D19 to D21 sit in the Updates section; this row holds "Kiểm tra cập nhật..." (PRD-R53).
struct CheckForUpdatesRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        HStack {
            Spacer()
            Button(action: model.checkForUpdates) { Text(verbatim: localizer.string(SupportText.checkNow)) }
                .disabled(!model.updater.canCheckForUpdates)
                .settingsAccessibility(SupportControl.checkNow, localizer)
        }
    }
}

struct HelpSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.string(SupportText.helpTitle)) {
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
            HStack {
                Button(action: model.reopenOnboarding) {
                    Text(verbatim: localizer.string(SupportText.reopenOnboarding))
                }
                .buttonStyle(.link)
                .settingsAccessibility(SupportControl.reopenOnboarding, localizer)
                Spacer(minLength: 0)
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
            RowLabel(title: localizer.format(SupportText.privacyBody, model.appName))
            HStack {
                Button(action: { model.showsLicences = true }) {
                    Text(verbatim: localizer.string(SupportText.licences))
                }
                .buttonStyle(.link)
                .settingsAccessibility(SupportControl.licences, localizer)
                Spacer(minLength: 0)
            }
        }
    }
}

/// PRD-R59 and Pa's decision S8: thank-you line, the bank VietQR code with the bank name and the account number in
/// text (never the holder's name: the payer's bank app shows it after the scan), and GitHub Sponsors once Pa has a
/// sponsor page. The image is bundled, never fetched; no donation prompt appears anywhere else (PRD-R58).
struct DonationSection: View {
    @ObservedObject var model: SettingsWindowModel
    let info = DonationInfo.standard

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.format(SupportText.donateTitle, model.appName)) {
            HStack(alignment: .top, spacing: SettingsMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel(title: localizer.format(SupportText.donateBody, model.appName))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: info.bankLine(localizer))
                        Text(verbatim: info.accountNumberLine(localizer))
                    }
                    .textSelection(.enabled)
                    Text(verbatim: localizer.string(SupportText.donateScanHint))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = info.githubSponsorsURL {
                        Link(destination: url) { Text(verbatim: localizer.string(SupportText.donateSponsors)) }
                            .settingsAccessibility(SupportControl.sponsorsLink, localizer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                QRCodeImage(
                    name: info.vietQRImageName, caption: localizer.string(SupportText.donateVietQR),
                    label: localizer.string(SupportText.donateVietQRImage))
            }
        }
    }
}

/// The QR code is a 1024 px image scaled down smoothly, so its modules stay even at any display scale.
struct QRCodeImage: View {
    let name: String
    let caption: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(name)
                .resizable()
                .interpolation(.high)
                .frame(width: 140, height: 140)
                .accessibilityLabel(Text(verbatim: label))
            Text(verbatim: caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Licences and acknowledgements: the bundled data's notices (ENG-R811) and Sparkle's licence.
struct LicencesSheet: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        // Read once per opening; the notices file ships in the bundle (VietnameseEngineData).
        let acknowledgements = Acknowledgements(dataNotices: Resources.bundledNotices, localizer: localizer)
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.string(SupportText.licencesTitle))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppLicenceRow(appName: model.appName, localizer: localizer)
                    ForEach(acknowledgements.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: localizer.string(section.title)).font(.headline)
                            Text(verbatim: section.text).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(action: { model.showsLicences = false }) {
                    Text(verbatim: localizer.string(SupportText.licencesClose))
                }
                .keyboardShortcut(.cancelAction)
                .settingsAccessibility(SupportControl.licencesClose, localizer)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

/// ADR 0006 (GPL-3.0 section 0, Appropriate Legal Notices): the app's own licence, "<app name>: GPL-3.0-or-later",
/// which shows the full text of the LICENSE file the bundle carries (project.yml). The file (35 KB) is read once
/// when the row appears and kept in view state, not on every render of the sheet or of the disclosure. No
/// disclosure animation with Reduce Motion (PRD-R67).
struct AppLicenceRow: View {
    let appName: String
    let localizer: Localizer
    @State private var text: String?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let title = localizer.format(SupportText.licencesApp, appName)
        DisclosureGroup(isExpanded: $expanded) {
            // Empty only in a broken bundle, which BuiltBundleTests.licenceIsBundled rejects.
            Text(verbatim: text ?? "")
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: title).font(.headline)
        }
        .settingsAccessibility(
            SupportControl.appLicence, localizer,
            label: localizer.accessibilityLabel(SupportControl.appLicence) + ": " + title
        )
        .transaction { if reduceMotion { $0.animation = nil } }  // PRD-R67
        .task { if text == nil { text = Self.bundledText() } }
    }

    /// Contents/Resources/LICENSE; nil only in a broken bundle (BuiltBundleTests checks the built app).
    static func bundledText(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "LICENSE", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
