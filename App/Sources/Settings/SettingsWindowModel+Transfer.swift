// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reset (PRD-R26), export and import (PLT-R1010, PRD-R72) and the Apps pane writes (PRD-R21, PRD-R36, PLT-R540).
// Files are read or written only where the user picked them; import data is untrusted and validated by the store
// (PLT-R912).

import AppKit
import AppModel
import CompatRules
import Foundation
import SettingsStore
import ShellCore

/// Export sheet choices (PLT-R1010: macros and per-app modes can be unticked).
struct ExportSheetState: Equatable {
    var includeMacros = true
    var includeAppModes = true
    /// Set when the sheet was opened from a reset confirmation, which reopens afterwards.
    var resumeReset: ResetRequest?
}

extension SettingsWindowModel {
    // MARK: Reset (PRD-R26)

    func requestReset(_ target: ResetTarget) { resetRequest = ResetRequest(target: target) }

    /// "Xuất cài đặt trước...": the reset sheet hands over to the export sheet and comes back after it.
    func exportBeforeReset() {
        guard let request = resetRequest else { return }
        resetRequest = nil
        exportSheet = ExportSheetState(resumeReset: request)
    }

    func confirmReset() {
        guard let request = resetRequest else { return }
        resetRequest = nil
        Task { apply(await commands.perform(request.plan)) }
    }

    // MARK: Export

    func requestExport() { exportSheet = ExportSheetState() }

    func cancelExport() {
        let resume = exportSheet?.resumeReset
        exportSheet = nil
        resetRequest = resume
    }

    func saveExport() {
        guard let sheet = exportSheet else { return }
        let options = ExportOptions(includeMacros: sheet.includeMacros, includeAppModes: sheet.includeAppModes)
        let now = Date()
        exportSheet = nil
        FilePanels.save(
            suggestedName: ExportOptions.fileName(slug: brand.slug, date: now),
            completion: { [weak self] url in
                guard let self else { return }
                Task { await self.writeExport(options, now: now, to: url, resume: sheet.resumeReset) }
            },
            cancelled: { [weak self] in self?.resetRequest = sheet.resumeReset })
    }

    private func writeExport(_ options: ExportOptions, now: Date, to url: URL, resume: ResetRequest?) async {
        do {
            try await FilePanels.writeOffMain(try await commands.export(options, now: now), to: url)
            if var resume {
                resume.exportedFileName = url.lastPathComponent
                resetRequest = resume
            } else {
                statusMessage = localizer.format(SettingsText.exportDone, url.lastPathComponent)
            }
        } catch {
            statusMessage = localizer.string(SettingsText.exportFailed)
            resetRequest = resume
        }
    }

    // MARK: Import

    func chooseImportFile() {
        importError = nil
        FilePanels.open(types: [.json]) { [weak self] url in
            guard let self else { return }
            Task { await self.previewImport(url) }
        }
    }

    private func previewImport(_ url: URL) async {
        guard let data = await FilePanels.readOffMain(url, maxBytes: SettingsExportFormat.maxImportBytes) else {
            importError = localizer.string(SettingsText.importErrorUnreadable)
            return
        }
        do {
            importSummary = ImportSummary(preview: try await commands.previewImport(data))
            importError = nil
        } catch {
            importSummary = nil
            importError = SettingsImportMessage.text(for: error, appName: appName, localizer)
        }
    }

    func confirmImport() {
        guard let summary = importSummary else { return }
        Task {
            do {
                apply(try await commands.applyImport(summary))
                importSummary = nil
                statusMessage = localizer.string(SettingsText.importDone)
            } catch {
                importError = SettingsImportMessage.text(for: error, appName: appName, localizer)
            }
        }
    }

    func cancelImport() {
        importSummary = nil
        importError = nil
    }

    // MARK: Apps pane

    var appRows: [AppsPaneRow] {
        AppsPaneModel.rows(
            appModes: state.appModes, overrides: state.ruleOverrides, matrix: matrix, today: SystemWallClock().now())
    }

    /// Name shown for a row (cached LaunchServices lookup, see AppIdentityCache).
    func appName(of row: AppsPaneRow) -> String {
        appIdentities.name(for: row.bundle, matrixName: row.matrixDisplayName)
    }

    func setRule(_ rule: PerAppRule, for bundle: BundleKey) {
        Task { apply(await commands.setRule(rule, for: bundle)) }
    }

    func showDetail(_ row: AppsPaneRow) {
        appDetail = AppDetail(row: row, matrix: matrix, today: SystemWallClock().now())
    }

    /// PRD-R36, PRD-R48: the paste mode asks first (clipboard explanation); the others apply at once.
    func chooseCompatibility(_ choice: CompatibilityModeChoice, for bundle: BundleKey) {
        if choice.needsClipboardExplanation {
            pendingPasteMode = bundle
            return
        }
        applyCompatibility(choice, for: bundle)
    }

    func confirmPasteMode() {
        guard let bundle = pendingPasteMode else { return }
        pendingPasteMode = nil
        applyCompatibility(.pasteText, for: bundle)
    }

    private func applyCompatibility(_ choice: CompatibilityModeChoice, for bundle: BundleKey) {
        Task {
            apply(await commands.setCompatibility(choice, for: bundle, at: Date()))
            if let detail = appDetail, detail.row.bundle == bundle,
                let row = appRows.first(where: { $0.bundle == bundle })
            {
                appDetail = AppDetail(row: row, matrix: matrix, today: SystemWallClock().now())
            }
        }
    }
}
