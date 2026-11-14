// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Giới thiệu / About" (PRD-R24; Pa, 15/11/2026: About & Support split into About, Support and Licences): the app's
// icon, name with its trademark sign, short description, version and build, the welcome guide, the update controls
// (D19-D21, PRD-R53) and the donation block (PRD-R57 to PRD-R59, `DonationSection`), each in its own grouped section.

import AppKit
import AppModel
import ShellCore
import SwiftUI

struct AboutPaneView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingsPaneForm {
            SettingsGroup { AboutHeader(model: model) }
            ForEach(SettingsCatalog.sections(in: .about), id: \.self) { section in
                SettingsGroup(header: section.header.map(localizer.string)) {
                    ForEach(section.rows, id: \.self) { row in SettingsSectionRow(model: model, items: row) }
                    // Only under the update settings, so a new About section never repeats the button.
                    if section.items.contains(.automaticallyCheckForUpdates) { CheckForUpdatesRow(model: model) }
                }
            }
            DonationSection(model: model)
        }
    }
}

/// The app's icon, marked name, description, version and build, and "Xem lại hướng dẫn làm quen" (PRD-R40).
struct AboutHeader: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: model.markedName).font(.title2.weight(.semibold))
                    Text(verbatim: localizer.string(SupportText.aboutDescription))
                    Text(verbatim: AboutSupportContent.versionLine(brand: model.brand, localizer: localizer))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Button(action: model.reopenOnboarding) {
                    Text(verbatim: localizer.string(SupportText.reopenOnboarding))
                }
                .buttonStyle(.link)
                .settingsAccessibility(SupportControl.reopenOnboarding, localizer)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
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
