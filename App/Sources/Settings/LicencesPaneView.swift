// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Bản quyền / Licences" (PRD-R24; Pa, 15/11/2026): the copyright line of the LICENSE files, the licence summary,
// the source repository once APP_REPOSITORY_URL is set, then the licences (the app's own GPL-3.0-or-later of
// ADR 0006 with the bundled LICENSE text, the MPL-2.0 engine) and the acknowledgements (the bundled data's notices of
// ENG-R811, Sparkle), each text under its own disclosure. This pane replaces the former licences sheet.

import AppKit
import AppModel
import ShellCore
import SwiftUI
import VietnameseEngine
import VietnameseEngineData

struct LicencesPaneView: View {
    @ObservedObject var model: SettingsWindowModel
    /// The bundled notices, read once when the pane appears rather than on every render.
    @State private var notices = BundledNotices.loading

    var body: some View {
        let localizer = model.localizer
        let acknowledgements = Acknowledgements(
            dataNotices: notices.text, appName: model.appName, localizer: localizer)
        SettingsPaneForm {
            SettingsGroup { CopyrightHeader(model: model) }
            SettingsGroup(header: localizer.string(SupportText.licencesSectionLicences)) {
                AppLicenceRow(appName: model.markedName, localizer: localizer)
                ForEach(acknowledgements.sections.filter { $0.title == .licencesEngine }) { section in
                    NoticeRow(section: section, localizer: localizer)
                }
            }
            SettingsGroup(header: localizer.string(SupportText.licencesSectionCredits)) {
                ForEach(acknowledgements.sections.filter { $0.title != .licencesEngine }) { section in
                    NoticeRow(section: section, localizer: localizer)
                }
            }
        }
        .task { if notices == .loading { notices = BundledNotices.read() } }
    }
}

/// ENG-R811: the notices file of VietnameseEngineData, read once per pane.
enum BundledNotices: Equatable {
    case loading
    case loaded(String)
    case unavailable

    struct Unavailable: Error {}

    static func read() -> BundledNotices {
        (try? Resources.bundledNotices()).map(BundledNotices.loaded) ?? .unavailable
    }

    /// The text for `Acknowledgements`: empty while loading (the disclosure is closed), the "could not be read" line
    /// of `Acknowledgements` when the file is missing.
    func text() throws -> String {
        switch self {
        case .loading: ""
        case .loaded(let text): text
        case .unavailable: throw Unavailable()
        }
    }
}

/// The marked name, "Bản quyền © 2026 các tác giả <name>", the licence summary and, once the repository is public,
/// "Xem mã nguồn".
struct CopyrightHeader: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: model.markedName).font(.title3.weight(.semibold))
            Text(verbatim: AboutSupportContent.copyrightLine(brand: model.brand, localizer: localizer))
                .textSelection(.enabled)
            Text(verbatim: localizer.format(SupportText.licencesSummary, model.markedName))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = model.brand.repositoryURL {
                Link(destination: url) { Text(verbatim: localizer.string(SupportText.licencesSource)) }
                    .settingsAccessibility(SupportControl.sourceLink, localizer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// One licence or notice: its title as a disclosure, the full text under it.
struct NoticeRow: View {
    let section: Acknowledgements.Section
    let localizer: Localizer
    @State private var expanded = false

    var body: some View {
        let title = localizer.string(section.title)
        SettingsDisclosure(
            title: title, isExpanded: $expanded, font: .body, control: SupportControl.notice, localizer: localizer,
            label: localizer.accessibilityLabel(SupportControl.notice) + ": " + title
        ) {
            NoticeText(text: section.text)
        }
    }
}

/// ADR 0006 (GPL-3.0 section 0, Appropriate Legal Notices): the app's own licence, "<app name>: GPL-3.0-or-later",
/// which shows the full text of the LICENSE file the bundle carries (project.yml). The file (35 KB) is read once
/// when the row appears and kept in view state, not on every render of the pane or of the disclosure.
struct AppLicenceRow: View {
    let appName: String
    let localizer: Localizer
    @State private var text: String?
    @State private var expanded = false

    var body: some View {
        let title = localizer.format(SupportText.licencesApp, appName)
        SettingsDisclosure(
            title: title, isExpanded: $expanded, font: .body, control: SupportControl.appLicence,
            localizer: localizer, label: localizer.accessibilityLabel(SupportControl.appLicence) + ": " + title
        ) {
            // Empty only in a broken bundle, which BuiltBundleTests.licenceIsBundled rejects.
            NoticeText(text: text ?? "")
        }
        .task { if text == nil { text = Self.bundledText() } }
    }

    /// Contents/Resources/LICENSE; nil only in a broken bundle (BuiltBundleTests checks the built app).
    static func bundledText(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "LICENSE", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A licence text in the small monospaced face, selectable.
struct NoticeText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
