// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Steps of the "This app misbehaves" panel (PLT-R1205): detected target, symptom, the empty-and-safe gate,
// progress with the "Do you see 'đá â'?" question, the suggestion with the opt-in page address, and the offers.

import AppModel
import Diagnostics
import InputHost
import ShellCore
import SwiftUI

struct MisbehavesView: View {
    @Bindable var model: MisbehavesModel

    var body: some View {
        let localizer = model.localizer
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let flow = model.flow {
                    TargetSummary(target: flow.target, localizer: localizer)
                    SymptomChips(
                        symptoms: DiagnosticsCopy.misbehavesSymptoms, selected: flow.symptom, localizer: localizer
                    ) { model.select($0) }
                    step(flow, localizer)
                }
                DisclosureGroup(isExpanded: $model.previewExpanded) {
                    ReportTextView(text: model.previewText, control: .reportText, localizer: localizer)
                        .frame(minHeight: 160)
                } label: {
                    Text(verbatim: localizer.string(DiagnosticsText.previewDisclosure))
                }
                .diagnosticsControl(.previewDisclosure, localizer)
                offers(localizer)
                if let status = model.status {
                    Text(verbatim: localizer.string(status)).font(.callout)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 420, minHeight: 360)
        .respectsReduceMotion()
    }

    @ViewBuilder
    private func step(_ flow: MisbehavesFlow, _ localizer: Localizer) -> some View {
        switch flow.step {
        case .describe:
            if model.targetIsThisApp {
                Text(verbatim: localizer.format(DiagnosticsText.ownAppFocused, model.brand.displayName))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canOfferGuidedTest {
                Text(verbatim: localizer.format(DiagnosticsText.guidedExplain, model.brand.displayName))
                    .fixedSize(horizontal: false, vertical: true)
                button(.guidedOffer, localizer) { model.requestGuidedTest() }
            }
        case .confirmField:
            Text(verbatim: localizer.string(DiagnosticsText.confirmText)).fixedSize(horizontal: false, vertical: true)
            button(.confirmField, localizer) { model.confirmAndStart() }
        case .testing(let index):
            progress(flow, index: index, localizer)
        case .askHuman:
            Text(verbatim: localizer.string(DiagnosticsText.ask)).font(.headline)
            HStack {
                button(.answerYes, localizer) { model.answer(seesCanary: true) }
                button(.answerNo, localizer) { model.answer(seesCanary: false) }
            }
        case .finished:
            FinishedStep(model: model, localizer: localizer)
        case .interrupted(let reason):
            Text(verbatim: localizer.string(Self.interruptionKey(reason)))
        }
    }

    private func progress(_ flow: MisbehavesFlow, index: Int, _ localizer: Localizer) -> some View {
        let candidate = flow.candidates[index]
        let method = DiagnosticsCopy.method(
            candidate.strategy, inlineCompletion: candidate.inlineCompletion,
            interEventDelayUs: candidate.interEventDelayUs, localizer)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: localizer.format(DiagnosticsText.testing, index + 1, flow.candidates.count, method))
            // A determinate bar: no animation is needed, so Reduce Motion has nothing to disable.
            ProgressView(value: Double(index), total: Double(flow.candidates.count))
            button(.stopTest, localizer) { model.stop() }
        }
    }

    @ViewBuilder
    private func offers(_ localizer: Localizer) -> some View {
        let offers = model.flow?.offers(hasRepository: model.brand.repositoryURL != nil) ?? [.copyReport]
        HStack(spacing: 8) {
            ForEach(offers.filter { $0 != .useForMe || model.services.applyOverride != nil }, id: \.self) { offer in
                button(Self.control(offer), localizer) { model.perform(offer) }
            }
        }
        Text(verbatim: localizer.format(DiagnosticsText.misbehavesClipboardNotice, model.brand.displayName))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ control: DiagnosticsControl, _ localizer: Localizer, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) { Text(verbatim: localizer.string(control.labelKey)) }
            .diagnosticsControl(control, localizer)
    }

    static func control(_ offer: MisbehavesOffer) -> DiagnosticsControl {
        switch offer {
        case .useForMe: .useForMe
        case .copySuggestion: .copySuggestion
        case .copyReport: .copyReport
        case .openGitHubIssue: .openGitHubIssue
        }
    }

    static func interruptionKey(_ reason: MisbehavesFlow.Interruption) -> DiagnosticsText {
        switch reason {
        case .focusChanged: .interruptedFocus
        case .fieldNotEmpty: .interruptedNotEmpty
        case .cancelled: .interruptedCancelled
        }
    }
}

/// PLT-R1205 step 2: app, field, rule and strategy as detected.
struct TargetSummary: View {
    let target: MisbehavesTarget
    let localizer: Localizer

    var body: some View {
        let unknown = localizer.string(DiagnosticsText.unknownValue)
        let app = target.app.map {
            [$0.bundle.rawValue, $0.appVersion?.original].compactMap { $0 }.joined(separator: " ")
        }
        let field = [target.field.role, target.field.subrole, target.field.identifier].compactMap { $0 }
        let method = DiagnosticsCopy.method(
            target.plan.strategy, inlineCompletion: target.plan.parameters.inlineCompletion,
            interEventDelayUs: target.plan.parameters.interEventDelayUs, localizer)
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: localizer.format(DiagnosticsText.detectedApp, app ?? unknown))
            Text(
                verbatim: localizer.format(
                    DiagnosticsText.detectedField, field.isEmpty ? unknown : field.joined(separator: ", ")))
            Text(verbatim: localizer.format(DiagnosticsText.detectedRule, target.rule?.rawValue ?? unknown))
            Text(verbatim: localizer.format(DiagnosticsText.detectedStrategy, method))
        }
        .font(.callout)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// Steps 4 and 5: the best method, the opt-in host-level page address and the suggestion JSON.
struct FinishedStep: View {
    @Bindable var model: MisbehavesModel
    let localizer: Localizer

    var body: some View {
        if model.flow?.couldNotReproduce == true {
            Text(verbatim: localizer.string(DiagnosticsText.resultNotReproduced)).fixedSize(
                horizontal: false, vertical: true)
        } else if let best = model.flow?.best {
            let method = DiagnosticsCopy.method(
                best.strategy, inlineCompletion: best.inlineCompletion, interEventDelayUs: best.interEventDelayUs,
                localizer)
            Text(verbatim: localizer.format(DiagnosticsText.resultFound, method)).font(.headline)
            Toggle(isOn: includeBinding) {
                Text(verbatim: localizer.string(DiagnosticsText.includePageAddress))
            }
            .diagnosticsControl(.includePageAddress, localizer)
            if model.flow?.includePageAddress == true {
                TextField(text: addressBinding) { Text(verbatim: localizer.string(DiagnosticsText.pageAddressField)) }
                    .diagnosticsControl(.pageAddressField, localizer)
                if let prefix = model.flow?.pageAddressPrefix {
                    Text(verbatim: localizer.format(DiagnosticsText.pageAddressPreview, prefix)).font(.footnote)
                }
            }
            if let json = model.suggestionJSON {
                Text(verbatim: localizer.string(DiagnosticsText.suggestionHeading)).font(.subheadline)
                ReportTextView(text: json, control: .copySuggestion, localizer: localizer).frame(minHeight: 120)
            }
        } else {
            Text(verbatim: localizer.string(DiagnosticsText.resultNone))
        }
    }

    private var includeBinding: Binding<Bool> {
        Binding(get: { model.flow?.includePageAddress ?? false }, set: { model.flow?.includePageAddress = $0 })
    }

    private var addressBinding: Binding<String> {
        Binding(get: { model.flow?.pageAddress ?? "" }, set: { model.flow?.pageAddress = $0 })
    }
}
