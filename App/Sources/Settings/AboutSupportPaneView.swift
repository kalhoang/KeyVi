// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Giới thiệu & Hỗ trợ / About & Support" (PRD-R24): version and channel, update controls (D19-D21, PRD-R53),
// diagnostics (D26), report a problem, export, import and reset, privacy summary, licences and acknowledgements
// (ENG-R811, Sparkle), and the donation block (PRD-R57-R59, bundled placeholder QR images marked VERIFY).

import AppKit
import AppModel
import ShellCore
import SwiftUI
import VietnameseEngine
import VietnameseEngineData

struct AboutSupportPaneView: View {
    let model: SettingsWindowModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.appName).font(.title2.weight(.semibold))
                    Text(verbatim: AboutSupportContent.versionLine(brand: model.brand, localizer: model.localizer))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                UpdatesSection(model: model)
                HelpSection(model: model)
                SettingsFilesSection(model: model)
                PrivacySection(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DonationBlock(model: model).frame(width: 230)
        }
    }
}

struct UpdatesSection: View {
    let model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let settings = model.settings
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.string(SupportText.updatesTitle))
            SettingRow(localizer: localizer, item: .updateChannel) {
                Picker(selection: Binding(get: { settings.updateChannel }, set: { model.selectChannel($0) })) {
                    Text(verbatim: localizer.string(SupportText.channelStable)).tag(UpdateChannel.stable)
                    Text(verbatim: localizer.string(SupportText.channelBeta)).tag(UpdateChannel.beta)
                } label: {
                    Text(verbatim: localizer.string(SupportText.channelTitle))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .settingsAccessibility(SupportControl.channel, localizer)
            }
            if let note = model.channelNote.text(appName: model.appName, localizer: localizer) {
                IssueLine(symbol: SettingsSymbol.info, text: note)
            }
            ToggleSetting(
                model: model, item: .automaticallyCheckForUpdates, control: SupportControl.autoCheck,
                isOn: settings.automaticallyCheckForUpdates
            ) { .automaticallyCheckForUpdates($0) }
            ToggleSetting(
                model: model, item: .automaticallyInstallUpdates, control: SupportControl.autoInstall,
                isOn: settings.automaticallyInstallUpdates
            ) { .automaticallyInstallUpdates($0) }
            Button(action: model.checkForUpdates) { Text(verbatim: localizer.string(SupportText.checkNow)) }
                .disabled(!model.updater.canCheckForUpdates)
                .settingsAccessibility(SupportControl.checkNow, localizer)
        }
    }
}

struct HelpSection: View {
    let model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 8) {
            PaneHeading(text: localizer.string(SupportText.helpTitle))
            HStack {
                Button(action: { model.reportProblem() }) {
                    Text(verbatim: localizer.string(SupportText.reportProblem))
                }
                .settingsAccessibility(SupportControl.reportProblem, localizer)
                Button(action: model.openDiagnostics) { Text(verbatim: localizer.string(SupportText.diagnostics)) }
                    .settingsAccessibility(SupportControl.diagnostics, localizer)
            }
            Text(verbatim: localizer.string(SupportText.diagnosticsExplanation)).font(.callout).foregroundStyle(
                .secondary)
            Button(action: model.reopenOnboarding) { Text(verbatim: localizer.string(SupportText.reopenOnboarding)) }
                .buttonStyle(.link)
                .settingsAccessibility(SupportControl.reopenOnboarding, localizer)
        }
    }
}

/// PRD-R24 and PLT-R1010: export, import and the global reset (PRD-R26).
struct SettingsFilesSection: View {
    let model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 8) {
            PaneHeading(text: localizer.string(SupportText.settingsTitle))
            HStack {
                Button(action: model.requestExport) { Text(verbatim: localizer.string(SupportText.exportSettings)) }
                    .settingsAccessibility(SupportControl.exportSettings, localizer)
                Button(action: model.chooseImportFile) { Text(verbatim: localizer.string(SupportText.importSettings)) }
                    .settingsAccessibility(SupportControl.importSettings, localizer)
                Button(action: { model.requestReset(.all) }) { Text(verbatim: localizer.string(SupportText.resetAll)) }
                    .settingsAccessibility(SupportControl.resetAll, localizer)
            }
        }
    }
}

struct PrivacySection: View {
    let model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            PaneHeading(text: localizer.string(SupportText.privacyTitle))
            Text(verbatim: localizer.format(SupportText.privacyBody, model.appName))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.showsLicences = true }) { Text(verbatim: localizer.string(SupportText.licences)) }
                .buttonStyle(.link)
                .settingsAccessibility(SupportControl.licences, localizer)
        }
    }
}

/// PRD-R59: thank-you line, VietQR with the account name in text, MoMo, GitHub Sponsors. Images are bundled, never
/// fetched; all details are placeholders until Pa verifies them (VERIFY).
struct DonationBlock: View {
    let model: SettingsWindowModel
    let info = DonationInfo.placeholder

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.format(SupportText.donateTitle, model.appName))
            Text(verbatim: localizer.format(SupportText.donateBody, model.appName))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                QRCodeImage(
                    name: info.vietQRImageName, caption: localizer.string(SupportText.donateVietQR),
                    label: localizer.string(SupportText.donateVietQRImage))
                QRCodeImage(
                    name: info.momoQRImageName, caption: localizer.string(SupportText.donateMoMo),
                    label: localizer.string(SupportText.donateMoMoImage))
            }
            Text(verbatim: info.accountLine(localizer)).font(.callout).textSelection(.enabled)
            if let url = info.githubSponsorsURL {
                Link(destination: url) { Text(verbatim: localizer.string(SupportText.donateSponsors)) }
                    .settingsAccessibility(SupportControl.sponsorsLink, localizer)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

struct QRCodeImage: View {
    let name: String
    let caption: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(name)
                .resizable()
                .interpolation(.none)
                .frame(width: 96, height: 96)
                .accessibilityLabel(Text(verbatim: label))
            Text(verbatim: caption).font(.caption)
        }
    }
}

/// Licences and acknowledgements: the bundled data's notices (ENG-R811) and Sparkle's licence.
struct LicencesSheet: View {
    let model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        // Read once per opening; the notices file ships in the bundle (VietnameseEngineData).
        let acknowledgements = Acknowledgements(dataNotices: Resources.bundledNotices, localizer: localizer)
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.string(SupportText.licencesTitle))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
