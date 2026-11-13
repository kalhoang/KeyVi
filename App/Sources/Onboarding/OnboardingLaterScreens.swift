// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding screens 4 to 8 (PRD-R40) and the permission help sheet (PLT-R740, PLT-R741).

import AppModel
import InputHost
import SettingsStore
import ShellCore
import SwiftUI

struct SwitchingScreen: View {
    let model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: localizer.string(OnboardingText.switchingTitle))
            Text(verbatim: localizer.string(OnboardingText.switchingBody))
            Text(verbatim: localizer.format(OnboardingText.switchingPerApp, model.appName))
            Text(verbatim: localizer.string(OnboardingText.switchingEnglishWords))
            let change = localizer.string(OnboardingText.switchingChangeKey)
            Button(action: model.openHotkeyRecorder) { Text(verbatim: change) }
                .buttonStyle(.link)
                .onboardingAccessibility(.changeToggleKey, localizer, label: change)
        }
    }
}

/// Shown only when another Vietnamese input method runs or the built-in source is enabled (PLT-R399). The app
/// never quits or changes other apps; it explains and links to help.
struct ConflictsScreen: View {
    let model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: localizer.string(OnboardingText.conflictsTitle))
            ForEach(Array(model.inputs.conflicts.enumerated()), id: \.offset) { _, conflict in
                ConflictRow(model: model, conflict: conflict)
            }
            let checkAgain = localizer.string(OnboardingText.conflictsCheckAgain)
            Button(action: model.checkConflictsAgain) { Text(verbatim: checkAgain) }
                .onboardingAccessibility(.checkAgain, localizer, label: checkAgain)
        }
    }
}

struct ConflictRow: View {
    let model: OnboardingModel
    let conflict: ConflictingInput

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 8) {
            switch conflict {
            case .runningApp(_, let name):
                Text(verbatim: localizer.format(OnboardingText.conflictsBody, name))
                let help = localizer.format(OnboardingText.conflictsHowToQuit, name)
                Button(action: { model.openConflictHelp(conflict) }) { Text(verbatim: help) }
                    .onboardingAccessibility(.conflictHelp, localizer, label: help)
            case .builtInVietnameseSource:
                Text(verbatim: localizer.format(OnboardingText.conflictsBuiltIn, model.appName))
                let open = localizer.format(OnboardingText.conflictsOpenKeyboard, model.panes.keyboard)
                Button(action: model.openKeyboardPane) { Text(verbatim: open) }
                    .onboardingAccessibility(.openKeyboardPane, localizer, label: open)
            }
        }
    }
}

/// PRD-R40 screen 6, PRD-R69: offered only for a detected export file or app; reading happens after the user
/// picks the file. The footer holds "Chọn tệp..." and "Để sau".
struct ImportScreen: View {
    let model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        let source = model.inputs.importCandidates.first?.appName ?? ""
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: localizer.format(OnboardingText.importTitle, source))
            Text(verbatim: localizer.format(OnboardingText.importBody, source))
        }
    }
}

struct TryItScreen: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: localizer.string(OnboardingText.tryItTitle))
            PracticeField(model: model, text: $model.tryItText, control: .tryItField)
            ForEach(TryItChecklist.Item.allCases, id: \.self) { item in
                ChecklistRow(model: model, item: item)
            }
        }
    }
}

struct ChecklistRow: View {
    let model: OnboardingModel
    let item: TryItChecklist.Item

    var body: some View {
        let localizer = model.localizer
        let done = model.checklist?.completed.contains(item) == true
        let text = label(localizer)
        // Done is a symbol change plus the spoken state, never colour alone (PRD-R67).
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: localizer.format(done ? OnboardingText.tryItItemDone : OnboardingText.tryItItemPending, text))
        )
    }

    private func label(_ localizer: Localizer) -> String {
        switch item {
        case .typeVietnamese:
            localizer.format(OnboardingText.tryItItemVietnamese, localizer.string(OnboardingText.tryItTargetVietnamese))
        case .typeEnglishWords:
            localizer.format(OnboardingText.tryItItemEnglish, localizer.string(OnboardingText.tryItTargetEnglish))
        case .toggleAndBack:
            localizer.string(OnboardingText.tryItItemToggle)
        }
    }
}

/// PRD-R40 screen 8: no donation prompt, no newsletter, no rating request.
struct DoneScreen: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ScreenTitle(text: localizer.string(OnboardingText.doneTitle))
                Spacer()
                // Placeholder arrow towards the menu bar icon (VERIFY with Pa).
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 40, weight: .semibold))
                    .accessibilityLabel(Text(verbatim: localizer.string(OnboardingText.doneArrow)))
            }
            Text(verbatim: localizer.format(OnboardingText.doneBody, model.appName)).font(.title3)
            Toggle(isOn: $model.openAtLogin) {
                Text(verbatim: localizer.format(OnboardingText.doneOpenAtLogin, model.appName))
            }
            .toggleStyle(.checkbox)
            .onboardingAccessibility(
                .openAtLogin, localizer, label: localizer.format(OnboardingText.doneOpenAtLogin, model.appName))
        }
    }
}

/// "Không thấy <App> trong danh sách?": remove and re-add, or reset only this app's entry after confirmation
/// (PLT-R740). Never mentions sudo or a reset of every app (PLT-R741).
struct PermissionHelpSheet: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        let help = model.helpContent
        VStack(alignment: .leading, spacing: 12) {
            ScreenTitle(text: help.title)
            ForEach(Array(help.steps.enumerated()), id: \.offset) { index, step in
                Text(verbatim: "\(localizer.formatNumber(index + 1)). \(step)")
            }
            Text(verbatim: help.resetIntro).font(.callout)
            HStack {
                Button(action: { model.confirmPermissionReset = true }) { Text(verbatim: help.resetButton) }
                    .onboardingAccessibility(.resetPermission, localizer, label: help.resetButton)
                Spacer()
                let close = localizer.string(CommonText.close)
                Button(action: { model.showPermissionHelp = false }) { Text(verbatim: close) }
                    .keyboardShortcut(.cancelAction)
                    .onboardingAccessibility(.closeHelp, localizer, label: close)
            }
            if model.permissionResetFailed {
                Label {
                    Text(verbatim: help.resetFailed).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
            }
            Divider()
            Text(verbatim: help.fallback).font(.footnote).foregroundStyle(.secondary)  // PLT-R206
        }
        .padding(24)
        .frame(width: 480)
        .alert(Text(verbatim: help.confirmTitle), isPresented: $model.confirmPermissionReset) {
            Button(role: .destructive, action: model.resetPermission) { Text(verbatim: help.confirmButton) }
                .onboardingAccessibility(.confirmResetPermission, localizer, label: help.confirmButton)
            let cancel = localizer.string(CommonText.cancel)
            Button(role: .cancel, action: {}) { Text(verbatim: cancel) }
                .onboardingAccessibility(.cancelResetPermission, localizer, label: cancel)
        } message: {
            Text(verbatim: help.confirmBody)
        }
    }
}

/// PRD-R40 screen 6 "Chọn tệp...": the Macros pane's preview before anything is merged (PRD-R32); a refused file
/// shows its reason with "Chọn tệp khác" (PRD-R43 "Import file invalid") and the flow stays on screen 6.
struct OnboardingImportSheet: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            ScreenTitle(text: localizer.string(MacrosText.importTitle))
            if let error = model.macroImport?.error {
                Label {
                    Text(verbatim: error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
            }
            if let session = model.macroImport?.session {
                MacroImportPreviewView(session: session, resolution: resolution, localizer: localizer)
            }
            HStack {
                Button(action: model.chooseImportFile) {
                    Text(verbatim: localizer.string(MacrosText.importChooseOther))
                }
                .settingsAccessibility(MacrosControl.importChooseOther, localizer)
                Spacer()
                Button(action: model.cancelImport) { Text(verbatim: localizer.string(MacrosText.importCancel)) }
                    .keyboardShortcut(.cancelAction)
                    .settingsAccessibility(MacrosControl.importCancel, localizer)
                Button(action: { Task { await model.confirmImport() } }) {
                    Text(verbatim: localizer.string(MacrosText.importConfirm))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.macroImport?.session == nil)
                .settingsAccessibility(MacrosControl.importConfirm, localizer)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var resolution: Binding<MacroDuplicateResolution> {
        Binding(
            get: { model.macroImport?.session?.resolution ?? .keepMine },
            set: { model.macroImport?.session?.resolution = $0 })
    }
}
