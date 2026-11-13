// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Own export format (PLT-R1010, PRD-R72), brand-neutral so renaming the app never breaks old exports:
//
//     {
//       "kind": "settings-export",
//       "schemaVersion": 1,
//       "writtenBy": "0.1.0",
//       "exportedAt": "2026-11-13T09:00:00Z",
//       "settings": { ...settings.json without envelope... },
//       "appModes": { ...app-modes.json without envelope... },   // optional (unticked = absent)
//       "ruleOverrides": [ ...stored overrides... ],
//       "macros": [ ...stored macros... ]                         // optional (unticked = absent)
//     }
//
// File name: `<slug>-settings-YYYYMMDD.json` (slug injected by the App).

public import AppModel
public import Foundation

public struct ExportOptions: Sendable, Hashable {
    public var includeMacros: Bool  // the sheet notes that macros may contain private text
    public var includeAppModes: Bool
    public init(includeMacros: Bool = true, includeAppModes: Bool = true) {
        self.includeMacros = includeMacros
        self.includeAppModes = includeAppModes
    }

    public static func fileName(slug: String, date: Date) -> String { unimplemented() }
}

public struct ImportPreview: Sendable, Hashable {
    public var schemaVersion: Int
    public var changedSettingKeys: [String]
    public var appEntries: Int
    public var ruleOverrides: Int
    public var macros: MacroImportPreview?
    /// Keys from a newer schema that this build will skip (PLT-R1010).
    public var skippedFields: [String]
    /// Opaque validated content applied by `applyImport`.
    public var content: JSONValue
}

public struct ImportChoices: Sendable, Hashable {
    public var applySettings: Bool
    public var applyAppModes: Bool
    public var applyRuleOverrides: Bool
    public var macroDuplicates: MacroDuplicateResolution
    public init(
        applySettings: Bool = true, applyAppModes: Bool = true, applyRuleOverrides: Bool = true,
        macroDuplicates: MacroDuplicateResolution = .keepMine
    ) {
        self.applySettings = applySettings
        self.applyAppModes = applyAppModes
        self.applyRuleOverrides = applyRuleOverrides
        self.macroDuplicates = macroDuplicates
    }
}
