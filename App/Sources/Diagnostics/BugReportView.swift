// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Báo lỗi..." sheet (PRD-R47-R49): app picker, symptom chips, the user's own example, the preview disclosure
// with the exact text, the clipboard notice before any clipboard write (PRD-R48) and the GitHub, email and
// save paths, plus the practice field. Logic lives in ShellCore's `BugReportSheet`.

import AppKit
import AppModel
import Diagnostics
import Observation
import ShellCore
import SwiftUI

@MainActor
@Observable
final class BugReportModel {
    let language: InterfaceLanguageModel
    @ObservationIgnored let services: DiagnosticsServices
    @ObservationIgnored var openPracticeField: () -> Void = {}
    @ObservationIgnored var window: () -> NSWindow? = { nil }
    private(set) var sheet: BugReportSheet
    private(set) var status: DiagnosticsText?
    /// The report shown in the preview and used by every path, regenerated only when a choice that it contains
    /// changes, so what the user saw is exactly what is copied, mailed or saved (PLT-R1204).
    private(set) var report: DiagnosticsReport
    @ObservationIgnored private let base: DiagnosticsReport

    init(
        draft: BugReportDraft, report: DiagnosticsReport, language: InterfaceLanguageModel,
        services: DiagnosticsServices
    ) {
        self.language = language
        self.services = services
        base = report
        let preselected = draft.app.map { BugReportAppChoice(bundle: $0, name: draft.appName ?? $0.rawValue) }
        var sheet = BugReportSheet(apps: services.recentApps(), preselected: preselected, brand: services.resolvedBrand)
        sheet.select(draft.symptom)
        sheet.setDescription(draft.userDescription)
        sheet.setReproducesInPracticeField(draft.reproducesInPracticeField)
        self.sheet = sheet
        self.report = sheet.report(from: services.reportForDraft?(sheet.draft) ?? report)
    }

    var localizer: Localizer { language.localizer }
    var brand: Brand { services.resolvedBrand }

    /// Rebuilt by the host when it can, else projected from the first report (PLT-R913).
    private func refreshReport() {
        report = sheet.report(from: services.reportForDraft?(sheet.draft) ?? base)
    }

    var previewText: String { sheet.preview(report, language: localizer.language) }

    var previewExpanded: Bool {
        get { sheet.previewExpanded }
        set { sheet.previewExpanded = newValue }
    }

    var description: String {
        get { sheet.draft.userDescription }
        set { sheet.setDescription(newValue) }
    }

    var selectedApp: BundleKey? {
        get { sheet.draft.app }
        set {
            sheet.selectApp(newValue)
            refreshReport()
        }
    }

    var practiceAnswer: Bool? {
        get { sheet.draft.reproducesInPracticeField }
        set {
            sheet.setReproducesInPracticeField(newValue)
            refreshReport()
        }
    }

    func select(_ symptom: DiagnosticsReport.Symptom) {
        sheet.select(symptom)
        refreshReport()
    }

    func perform(_ action: BugReportAction) {
        switch action {
        case .copyReport:
            ReportActions.copy(sheet.clipboardText(report))
            status = .copied
        case .github: openGitHub()
        case .email: sendEmail()
        case .saveFile: saveFile()
        case .practiceField: openPracticeField()
        case .openDiagnostics: openDiagnostics()
        }
    }

    private func openGitHub() {
        guard let repository = brand.repositoryURL else { return }
        let current = report
        // PRD-R47 item 5: the block goes to the clipboard (after the visible notice), the summary into the URL.
        ReportActions.copy(sheet.clipboardText(current))
        ReportActions.open(sheet.githubURL(repository: repository, report: current))
        status = .githubPasteHint
    }

    private func sendEmail() {
        let current = report
        guard let draft = sheet.mail(report: current, brand: brand, localizer: localizer),
            let data = try? sheet.attachment(current)
        else { return }
        switch ReportActions.email(draft, attachment: data) {
        case .composed: status = nil
        case .fallbackWithoutAttachment: status = .emailFallback
        case .unavailable: status = .emailUnavailable
        }
    }

    private func saveFile() {
        let current = report
        guard let data = try? sheet.attachment(current) else {
            status = .saveFailed
            return
        }
        ReportActions.save(
            suggestedName: sheet.attachmentFileName(slug: brand.slug, report: current), over: window(),
            write: { url in (try? data.write(to: url, options: .atomic)) != nil },
            done: { [weak self] saved in
                guard let saved else { return }
                self?.status = saved ? .saved : .saveFailed
            })
    }

    @ObservationIgnored var openDiagnostics: () -> Void = {}
}

struct BugReportView: View {
    @Bindable var model: BugReportModel

    var body: some View {
        let localizer = model.localizer
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                appPicker(localizer)
                SymptomChips(
                    symptoms: DiagnosticsCopy.sheetSymptoms, selected: model.sheet.draft.symptom, localizer: localizer
                ) { model.select($0) }
                descriptionField(localizer)
                practiceField(localizer)
                DisclosureGroup(isExpanded: $model.previewExpanded) {
                    ReportTextView(text: model.previewText, control: .reportText, localizer: localizer)
                        .frame(minHeight: 180)
                } label: {
                    Text(verbatim: localizer.string(DiagnosticsText.previewDisclosure))
                }
                .diagnosticsControl(.previewDisclosure, localizer)
                Text(verbatim: localizer.format(DiagnosticsText.clipboardNotice, model.brand.displayName))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions(localizer)
                if let status = model.status {
                    Text(verbatim: localizer.string(status)).font(.callout)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 520)
        .respectsReduceMotion()
    }

    private func appPicker(_ localizer: Localizer) -> some View {
        Picker(selection: $model.selectedApp) {
            Text(verbatim: localizer.string(DiagnosticsText.appNone)).tag(BundleKey?.none)
            ForEach(model.sheet.apps, id: \.bundle) { app in
                Text(verbatim: app.name).tag(BundleKey?.some(app.bundle))
            }
        } label: {
            Text(verbatim: localizer.string(DiagnosticsText.appLabel))
        }
        .diagnosticsControl(.appPicker, localizer)
    }

    private func descriptionField(_ localizer: Localizer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: localizer.string(DiagnosticsText.descriptionLabel))
            TextEditor(text: $model.description)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .diagnosticsControl(.description, localizer)
            Text(verbatim: localizer.format(DiagnosticsText.descriptionNote, model.brand.displayName))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func practiceField(_ localizer: Localizer) -> some View {
        HStack(spacing: 10) {
            Button {
                model.perform(.practiceField)
            } label: {
                Text(verbatim: localizer.string(DiagnosticsText.practiceButton))
            }
            .diagnosticsControl(.practiceButton, localizer)
            Picker(selection: $model.practiceAnswer) {
                Text(verbatim: localizer.string(DiagnosticsText.practiceUnknown)).tag(Bool?.none)
                Text(verbatim: localizer.string(DiagnosticsText.practiceYes)).tag(Bool?.some(true))
                Text(verbatim: localizer.string(DiagnosticsText.practiceNo)).tag(Bool?.some(false))
            } label: {
                Text(verbatim: localizer.string(DiagnosticsText.practiceLabel))
            }
            .diagnosticsControl(.practiceAnswer, localizer)
        }
    }

    private func actions(_ localizer: Localizer) -> some View {
        HStack(spacing: 8) {
            ForEach(model.sheet.actions.filter { $0 != .practiceField }, id: \.self) { action in
                let control = Self.control(action)
                Button {
                    model.perform(action)
                } label: {
                    Text(verbatim: localizer.string(control.labelKey))
                }
                .diagnosticsControl(control, localizer)
            }
        }
    }

    static func control(_ action: BugReportAction) -> DiagnosticsControl {
        switch action {
        case .copyReport: .copyReport
        case .github: .github
        case .email: .email
        case .saveFile: .saveFile
        case .practiceField: .practiceButton
        case .openDiagnostics: .openDiagnostics
        }
    }
}

/// Symptom chips as toggle buttons; the selected chip is marked by a checkmark and the selected trait, not by
/// colour alone (PRD-R67).
struct SymptomChips: View {
    let symptoms: [DiagnosticsReport.Symptom]
    let selected: DiagnosticsReport.Symptom?
    let localizer: Localizer
    let choose: (DiagnosticsReport.Symptom) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localizer.string(DiagnosticsText.symptomLabel))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                ForEach(symptoms, id: \.self) { symptom in
                    let isSelected = symptom == selected
                    Button {
                        choose(symptom)
                    } label: {
                        Label {
                            Text(verbatim: DiagnosticsCopy.symptom(symptom, localizer))
                        } icon: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    .accessibilityLabel(Text(verbatim: DiagnosticsCopy.symptom(symptom, localizer)))
                    .accessibilityHint(Text(verbatim: localizer.string(DiagnosticsControl.symptom.hintKey)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}
