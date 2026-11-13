// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Settings window layout: the five panes in PRD-R24 order behind a segmented pane picker (keyboard reachable),
// store notices on top, the current pane, and the sheets of the reset, export, import, macro and app flows.

import AppModel
import ShellCore
import SwiftUI

struct SettingsRootView: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 0) {
            Picker(selection: Binding(get: { model.selectedPane }, set: { model.select($0) })) {
                ForEach(SettingsPaneKind.allCases, id: \.self) { pane in
                    Text(verbatim: localizer.string(pane.title)).tag(pane)
                }
            } label: {
                Text(verbatim: localizer.accessibilityLabel(SettingsControl.panePicker))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .settingsAccessibility(SettingsControl.panePicker, localizer)
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
            ForEach(model.notices, id: \.self) { notice in
                NoticeBanner(model: model, notice: notice).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            pane
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let message = model.statusMessage {
                Divider()
                Text(verbatim: message).font(.callout).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .frame(
            minWidth: SettingsWindowController.minimumSize.width, minHeight: SettingsWindowController.minimumSize.height
        )
        .modifier(SettingsSheets(model: model))
    }

    @ViewBuilder private var pane: some View {
        switch model.selectedPane {
        case .general: ScrollView { GeneralPaneView(model: model) }
        case .typing: ScrollView { TypingPaneView(model: model) }
        case .apps: AppsPaneView(model: model)
        case .macros: MacrosPaneView(model: model)
        case .aboutSupport: ScrollView { AboutSupportPaneView(model: model) }
        }
    }
}

/// Every sheet and alert of the window, driven by optional model state.
struct SettingsSheets: ViewModifier {
    @Bindable var model: SettingsWindowModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presence(\.resetRequest)) { ResetSheet(model: model) }
            .sheet(isPresented: presence(\.exportSheet)) { ExportSheet(model: model) }
            .sheet(isPresented: importPresented) { ImportSheet(model: model) }
            .sheet(isPresented: presence(\.macroDraft)) { MacroEditorSheet(model: model) }
            .sheet(isPresented: macroImportPresented) { MacroImportSheet(model: model) }
            .sheet(isPresented: presence(\.appDetail)) { AppDetailSheet(model: model) }
            .sheet(isPresented: $model.showsLicences) { LicencesSheet(model: model) }
            .modifier(MacroDeleteAlert(model: model))
            .modifier(PasteModeAlert(model: model))
    }

    private func presence<Value>(_ keyPath: ReferenceWritableKeyPath<SettingsWindowModel, Value?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] != nil }, set: { if !$0 { model[keyPath: keyPath] = nil } })
    }

    private var importPresented: Binding<Bool> {
        Binding(
            get: { model.importSummary != nil || model.importError != nil },
            set: { if !$0 { model.cancelImport() } })
    }

    private var macroImportPresented: Binding<Bool> {
        Binding(
            get: { model.macroImport != nil || model.macroImportError != nil },
            set: {
                if !$0 {
                    model.macroImport = nil
                    model.macroImportError = nil
                }
            })
    }
}
