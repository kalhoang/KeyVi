// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window layout in the style of macOS System Settings (Pa, 2026-11-14, feedback item 6): the sidebar with
// the seven panes in PRD-R24 order on the left, running the window's full height under the transparent title bar; on
// the right the pane's title in the title bar row, the store notices, then the pane's grouped sections, and the short
// status line at the bottom. Also the sheets of the reset, export, import, macro and app flows and the learned words.

import AppModel
import ShellCore
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        // The title bar's height is the top safe area (`SettingsWindowController.configure`); both columns run under
        // it and keep their content below it.
        GeometryReader { proxy in
            HStack(spacing: 0) {
                SettingsSidebar(model: model, titleBarHeight: proxy.safeAreaInsets.top)
                Divider()
                SettingsDetail(model: model, titleBarHeight: proxy.safeAreaInsets.top)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(
            minWidth: SettingsWindowLayout.minimumWidth, maxWidth: .infinity,
            minHeight: SettingsWindowLayout.minimumHeight, maxHeight: .infinity
        )
        // PRD-R67: with Reduce Motion on, no implicit SwiftUI animation runs anywhere in the window.
        .respectsReduceMotion()
        .modifier(SettingsSheets(model: model))
    }
}

/// The right-hand column: title in the title bar row, notices (PLT-R1006, PLT-R1007, PLT-R1009), the pane, the
/// status line.
struct SettingsDetail: View {
    @ObservedObject var model: SettingsWindowModel
    let titleBarHeight: CGFloat

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: localizer.string(model.selectedPane.title))
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, SettingsMetrics.paneInset)
                .frame(height: max(titleBarHeight, SettingsMetrics.minimumTitleRowHeight))
                // The pane starts a little below the title bar row: a scroll view whose top edge meets the title
                // bar would extend under it and cover the title.
                .padding(.bottom, model.notices.isEmpty ? SettingsMetrics.titleRowGap : 8)
            ForEach(model.notices, id: \.self) { notice in
                NoticeBanner(model: model, notice: notice)
                    .padding(.horizontal, SettingsMetrics.paneInset)
                    .padding(.bottom, 8)
            }
            pane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let message = model.statusMessage {
                Divider()
                Text(verbatim: message)
                    .font(.callout)
                    .padding(.horizontal, SettingsMetrics.paneInset)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var pane: some View {
        switch model.selectedPane {
        case .general: SettingsSectionsPane(model: model, pane: .general)
        case .typing: SettingsSectionsPane(model: model, pane: .typing)
        case .apps: AppsPaneView(model: model)
        case .macros: MacrosPaneView(model: model)
        case .about: AboutPaneView(model: model)
        case .support: SupportPaneView(model: model)
        case .licences: LicencesPaneView(model: model)
        }
    }
}

/// Every sheet and alert of the window, driven by optional model state.
struct SettingsSheets: ViewModifier {
    @ObservedObject var model: SettingsWindowModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presence(\.resetRequest)) { ResetSheet(model: model).respectsReduceMotion() }
            .sheet(isPresented: presence(\.exportSheet)) { ExportSheet(model: model).respectsReduceMotion() }
            .sheet(isPresented: importPresented) { ImportSheet(model: model).respectsReduceMotion() }
            .sheet(isPresented: presence(\.macroDraft)) { MacroEditorSheet(model: model).respectsReduceMotion() }
            .sheet(isPresented: macroImportPresented) { MacroImportSheet(model: model).respectsReduceMotion() }
            .sheet(isPresented: presence(\.appDetail)) { AppDetailSheet(model: model).respectsReduceMotion() }
            .sheet(isPresented: presence(\.learnedChoices)) { LearnedChoicesSheet(model: model).respectsReduceMotion() }
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
