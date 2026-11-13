// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Nhập từ tệp..." in the Macros pane (PRD-R32, PRD-R70): a file the user picked is parsed by SettingsStore's
// tolerant importer, previewed with counts of new, duplicate and invalid rows, and merged with the user's choice
// for duplicates. Counts are the importer's own (`MacroImportPreview`), so the sheet and W1-B always agree.

public import Foundation
public import SettingsStore

public enum MacroImportRefusal: Error, Sendable, Hashable {
    case tooLarge
    case empty
    /// Nothing importable. `firstInvalid` gives the PRD-R43 line ("Dòng 12: thiếu phần nội dung gõ tắt."), nil
    /// when the file could not be read as any format.
    case invalidFile(firstInvalid: MacroImportRow?)
}

public struct MacroImportSession: Sendable, Hashable {
    public let preview: MacroImportPreview
    public var resolution = MacroDuplicateResolution.keepMine

    public init(preview: MacroImportPreview) { self.preview = preview }

    /// Parses `data` (format sniffed from content, then extension) against the user's macros.
    public static func open(_ data: Data, fileExtension: String?, existing: [StoredMacro])
        -> Result<MacroImportSession, MacroImportRefusal>
    {
        guard data.count <= MacroImporter.maxFileBytes else { return .failure(.tooLarge) }
        guard let format = MacroImporter.detectFormat(data, fileExtension: fileExtension) else {
            return .failure(.invalidFile(firstInvalid: nil))
        }
        let rows = MacroImporter.parse(data, format: format)
        guard !rows.isEmpty else { return .failure(.empty) }
        let preview = MacroImporter.preview(rows, existing: existing)
        if preview.new.isEmpty, preview.duplicates.isEmpty {
            let unreadable = preview.invalid.count == 1 && preview.invalid[0].issue == .malformedLine
            return .failure(.invalidFile(firstInvalid: unreadable ? nil : preview.invalid.first))
        }
        return .success(MacroImportSession(preview: preview))
    }

    public var newCount: Int { preview.new.count }
    public var duplicateCount: Int { preview.duplicates.count }
    public var invalidCount: Int { preview.invalid.count }

    /// The merged list to save: expansions in NFC (ENG-R1101), checked by the engine before saving.
    public func merged(into existing: [StoredMacro]) -> Result<[StoredMacro], MacroTableProblem> {
        let merged = MacroImporter.merge(preview, into: existing, resolution: resolution).map { macro in
            var normalized = macro
            normalized.expansion = MacroDraftValidator.normalizedExpansion(macro.expansion)
            return normalized
        }
        if let problem = MacroDraftValidator.engineProblem(in: merged) { return .failure(problem) }
        return .success(merged)
    }

    /// Invalid rows with their line and reason, in file order.
    public func invalidLines(_ localizer: Localizer) -> [String] {
        preview.invalid.map { MacroIssueText.lineText($0, localizer: localizer) }
    }
}

extension MacroImportRefusal {
    public func message(_ localizer: Localizer) -> String {
        switch self {
        case .tooLarge:
            return localizer.format(MacrosText.importTooLarge, SizeText.megabytes(MacroImporter.maxFileBytes, localizer))
        case .empty: return localizer.string(MacrosText.importEmpty)
        case .invalidFile(nil): return localizer.string(MacrosText.importInvalidFile)
        case .invalidFile(let row?):
            let reason = MacroIssueText.lineReason(row, localizer: localizer) ?? ""
            return localizer.format(MacrosText.importInvalidFileLine, row.line, reason)
        }
    }
}
