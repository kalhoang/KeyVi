// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the catalog audit compares (PRD-R62, ADR 0310): the String Catalog files on disk, the keys the code refers
// to through typed enums (ShellCore's `LocalizationKey` and control enums, and the App target's `UpdatesText`,
// read from its source because the App target is not importable here), the brand values of
// `Config/Brand.xcconfig`, and the Swift sources of the app.

import Foundation
import Testing

@testable import ShellCore

enum CatalogInventory {
    static let directory = "App/Resources/Localization"

    /// Catalog file names without extension, as found on disk.
    static func tablesOnDisk() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(
            at: RepoPaths.url(directory), includingPropertiesForKeys: nil)
        return Set(
            files.filter { $0.pathExtension == "xcstrings" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    // MARK: Keys referenced by code

    /// Every key the code can look up, per table. A table missing here fails the audit, so a new table cannot
    /// ship unchecked.
    static func referencedKeys() throws -> [StringTable: Set<String>] {
        var keys: [StringTable: Set<String>] = [:]
        for typed in try typedKeys() {
            keys[typed.table, default: []].insert(typed.key)
        }
        return keys
    }

    /// One key with the Swift name of the enum case that declares it (empty for keys built from another value).
    struct TypedKey: Hashable {
        var table: StringTable
        var key: String
        var caseName: String
        var enumName: String
    }

    static func typedKeys() throws -> [TypedKey] {
        var result: [TypedKey] = []
        func add<Key: LocalizationKey>(_ type: Key.Type) {
            result += type.allCases.map {
                TypedKey(
                    table: Key.table, key: $0.rawValue, caseName: String(describing: $0),
                    enumName: String(describing: type))
            }
        }
        func controls<Control: AccessibleControl>(_ type: Control.Type) {
            for control in type.allCases {
                for key in [control.accessibilityLabelKey, control.accessibilityHintKey] {
                    result.append(
                        TypedKey(
                            table: Control.table, key: key, caseName: String(describing: control),
                            enumName: String(describing: type)))
                }
            }
        }
        add(CommonText.self)
        add(MenuText.self)
        add(StatusText.self)
        add(OnboardingText.self)
        add(SettingsText.self)
        add(MacrosText.self)
        add(AppsText.self)
        add(SupportText.self)
        add(DiagnosticsText.self)
        add(CompositionText.self)
        #if DEV_RECORDER
        add(DevRecorderText.self)
        #endif
        controls(SettingsControl.self)
        controls(MacrosControl.self)
        controls(AppsControl.self)
        controls(SupportControl.self)
        for control in OnboardingControl.allCases {
            for key in [control.accessibilityLabelKey, control.accessibilityHintKey] {
                result.append(
                    TypedKey(
                        table: .onboarding, key: key, caseName: control.rawValue, enumName: "OnboardingControl"))
            }
        }
        // Icon labels are built from the icon state (`icon.<state>.accessibilityLabel`); `MenuText` mirrors them.
        for state in StatusIconState.allCases {
            result.append(
                TypedKey(table: .menu, key: state.accessibilityLabelKey, caseName: "", enumName: "StatusIconState"))
        }
        result += try updatesKeys()
        return result
    }

    /// `UpdatesText` and `UpdateFailureControl` live in the App target (App/Sources/Updater/UpdatesText.swift); the
    /// keys are read from the source. The Updater's own catalog test checks the same keys at run time.
    static func updatesKeys() throws -> [TypedKey] {
        let source = try String(
            contentsOf: RepoPaths.url("App/Sources/Updater/UpdatesText.swift"), encoding: .utf8)
        var keys: [TypedKey] = source.matches(of: /case (\w+) = "(updates\.[A-Za-z.]+)"/).map {
            TypedKey(table: .updates, key: String($0.output.2), caseName: String($0.output.1), enumName: "UpdatesText")
        }
        let controlsBlock = try #require(
            source.firstMatch(of: /enum UpdateFailureControl[^{]*\{\s*case ([\w, ]+)\n/), "UpdateFailureControl")
        let controls = controlsBlock.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let templates = source.matches(of: /"(updates\.control\.)\\\(rawValue\)(\.accessibility[A-Za-z]+)"/)
        #expect(templates.count == 2, "label and hint templates of UpdateFailureControl")
        for control in controls {
            for template in templates {
                keys.append(
                    TypedKey(
                        table: .updates, key: "\(template.output.1)\(control)\(template.output.2)",
                        caseName: control, enumName: "UpdateFailureControl"))
            }
        }
        return keys
    }

    // MARK: Brand

    /// Values of `Config/Brand.xcconfig`, the single source of the temporary name (CLAUDE.md).
    struct Brand {
        var displayName: String
        var slug: String
        var bundleIDs: [String]
        var siteHost: String
    }

    static func brand() throws -> Brand {
        let text = try String(contentsOf: RepoPaths.url("Config/Brand.xcconfig"), encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("//") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return Brand(
            displayName: try #require(values["APP_DISPLAY_NAME"]), slug: try #require(values["APP_SLUG"]),
            bundleIDs: [try #require(values["APP_BUNDLE_ID_RELEASE"]), try #require(values["APP_BUNDLE_ID_DEV"])],
            siteHost: try #require(values["APP_SITE_HOST"]))
    }

    // MARK: Sources

    /// UI folders of the App target (the Updater's tests are excluded by `productionSources`).
    static let uiFolders = [
        "App/Sources/Shell/", "App/Sources/Onboarding/", "App/Sources/Settings/", "App/Sources/Diagnostics/",
        "App/Sources/Composition/", "App/Sources/Updater/",
    ]

    static func uiSources() throws -> [(path: String, lines: [String])] {
        try productionSources()
            .filter { source in uiFolders.contains { source.path.hasPrefix($0) } }
            .map { ($0.path, $0.text.components(separatedBy: "\n")) }
    }

    /// Swift sources that ship: the App target (without its test folders) and every AppCore module.
    static func productionSources() throws -> [(path: String, text: String)] {
        var result: [(String, String)] = []
        for root in ["App/Sources", "Packages/AppCore/Sources"] {
            let base = RepoPaths.url(root)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = url.path.replacingOccurrences(of: RepoPaths.root.path + "/", with: "")
                if relative.contains("/Tests/") { continue }
                result.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

/// One catalog entry with everything the audit inspects.
struct AuditedEntry {
    struct Unit {
        var state: String?
        var value: String?
    }

    var key: String
    var extractionState: String?
    var units: [String: Unit]  // language -> unit
}

struct AuditedCatalog {
    let table: StringTable
    let sourceLanguage: String?
    let version: String?
    let entries: [AuditedEntry]

    init(table: StringTable) throws {
        self.table = table
        let url = RepoPaths.url("\(CatalogInventory.directory)/\(table.rawValue).xcstrings")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(table.rawValue)")
        sourceLanguage = object["sourceLanguage"] as? String
        version = object["version"] as? String
        let strings = object["strings"] as? [String: Any] ?? [:]
        entries = strings.keys.sorted().map { key in
            let raw = strings[key] as? [String: Any] ?? [:]
            let localizations = raw["localizations"] as? [String: Any] ?? [:]
            var units: [String: AuditedEntry.Unit] = [:]
            for (language, value) in localizations {
                let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
                units[language] = AuditedEntry.Unit(state: unit?["state"] as? String, value: unit?["value"] as? String)
            }
            return AuditedEntry(key: key, extractionState: raw["extractionState"] as? String, units: units)
        }
    }
}
