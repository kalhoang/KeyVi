// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Macros pane actions (PRD-R29-R33). Every change is validated in ShellCore (MacroValidator and the engine's
// MacroTable) before `SettingsStore.replaceMacros`; files are read or written only where the user picked them.
// Macro content is never logged (PRD-R33).

import AppKit
import AppModel
import Foundation
import SettingsStore
import ShellCore

extension SettingsWindowModel {
    var macroIssues: [UUID: MacroRowIssue] { macroList.rowIssues }

    func draftCheck(_ draft: MacroDraft) -> MacroDraftCheck {
        MacroDraftValidator.check(draft, among: macroList.macros, method: settings.typingMethod)
    }

    func addMacro() {
        macroDraftError = nil
        macroDraft = MacroDraft()
    }

    func editMacro(_ id: UUID) {
        macroDraftError = nil
        macroDraft = macroList.draft(for: id)
    }

    func duplicateMacro(_ id: UUID) {
        macroDraftError = nil
        macroDraft = macroList.duplicateDraft(of: id)
    }

    /// Saves the sheet's draft; on failure the sheet stays open with the reason (row context for the engine).
    func saveMacroDraft(_ draft: MacroDraft) {
        var list = macroList
        switch list.save(draft, method: settings.typingMethod) {
        case .success:
            macroList = list
            macroDraft = nil
            macroDraftError = nil
            persistMacros()
        case .failure(.invalid(let issue)):
            macroDraftError = MacroIssueText.text(issue, shortcut: draft.shortcut, localizer: localizer)
        case .failure(.rejectedByEngine(let problem)):
            macroDraftError = localizer.format(
                MacrosText.saveFailed, MacroIssueText.entryText(problem, localizer: localizer))
        case .failure(.notFound):
            macroDraft = nil
        }
    }

    func confirmDeleteMacro() {
        guard let macro = macroToDelete else { return }
        macroList.delete(macro.id)
        macroToDelete = nil
        persistMacros()
    }

    func setMacroEnabled(_ enabled: Bool, id: UUID) {
        macroList.setEnabled(enabled, for: id)
        persistMacros()
    }

    func setAllMacrosEnabled(_ enabled: Bool) {
        macroList.setAllEnabled(enabled)
        persistMacros()
    }

    private func persistMacros() {
        let macros = macroList.macros
        Task { apply(await commands.saveMacros(macros)) }
    }

    // MARK: Import and export (PRD-R32, PRD-R2)

    func chooseMacroFile() {
        FilePanels.open(types: FilePanels.macroTypes) { [weak self] url in self?.openMacroFile(url) }
    }

    func openMacroFile(_ url: URL) {
        macroImportError = nil
        guard let data = FilePanels.read(url, maxBytes: MacroImporter.maxFileBytes) else {
            macroImport = nil
            macroImportError = localizer.string(MacrosText.importUnreadable)
            return
        }
        switch MacroImportSession.open(data, fileExtension: url.pathExtension, existing: macroList.macros) {
        case .success(let session): macroImport = session
        case .failure(let refusal):
            macroImport = nil
            macroImportError = refusal.message(localizer)
        }
    }

    func confirmMacroImport() {
        guard let session = macroImport else { return }
        switch session.merged(into: macroList.macros) {
        case .success(let merged):
            macroList.replace(with: merged)
            macroImport = nil
            statusMessage = localizer.string(MacrosText.importDone)
            persistMacros()
        case .failure(let problem):
            macroImportError = localizer.format(
                MacrosText.saveFailed, MacroIssueText.entryText(problem, localizer: localizer))
        }
    }

    func exportMacros() {
        let name = MacroExport.fileName(slug: brand.slug, date: Date())
        let macros = macroList.macros
        FilePanels.save(suggestedName: name) { [weak self] url in
            guard let self else { return }
            do {
                try FilePanels.write(try MacroExport.data(macros), to: url)
                statusMessage = localizer.format(SettingsText.exportDone, url.lastPathComponent)
            } catch {
                statusMessage = localizer.string(MacrosText.exportFailed)
            }
        }
    }
}
