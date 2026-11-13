// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test helpers: locate the repository, parse String Catalogs and build a throwaway app bundle whose
// `vi.lproj` / `en.lproj` hold `.strings` files compiled from the real catalogs (the same layout Xcode
// produces, ADR 0310), so `Localizer` is tested against the shipped copy.

import Foundation

@testable import ShellCore

enum RepoPaths {
    /// Repository root: the first ancestor of this file that contains `project.yml`.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
            url.deleteLastPathComponent()
        }
        fatalError("repository root not found")
    }()

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
}

/// One String Catalog (`.xcstrings`) as plain values.
struct Catalog {
    struct Entry {
        var values: [String: String]  // language -> value
    }

    let name: String
    let sourceLanguage: String
    let entries: [String: Entry]

    init(table: StringTable) throws {
        try self.init(url: RepoPaths.url("App/Resources/Localization/\(table.rawValue).xcstrings"))
    }

    init(url: URL) throws {
        name = url.deletingPathExtension().lastPathComponent
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        sourceLanguage = object["sourceLanguage"] as? String ?? ""
        let strings = object["strings"] as? [String: Any] ?? [:]
        var entries: [String: Entry] = [:]
        for (key, raw) in strings {
            let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            var values: [String: String] = [:]
            for (language, unit) in localizations {
                let stringUnit = (unit as? [String: Any])?["stringUnit"] as? [String: Any]
                if let value = stringUnit?["value"] as? String { values[language] = value }
            }
            entries[key] = Entry(values: values)
        }
        self.entries = entries
    }
}

/// Format specifiers of a printf-style string, normalised to (position, conversion) so positional and
/// sequential forms compare equal ("%@ %d" == "%1$@ %2$d").
enum FormatSpecifiers {
    static func of(_ text: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])/
        var sequential = 0
        var result: Set<String> = []
        for match in text.matches(of: pattern) {
            let conversion = String(match.output.2)
            if conversion == "%" { continue }
            let position: Int
            if let explicit = match.output.1, let value = Int(explicit) {
                position = value
            } else {
                sequential += 1
                position = sequential
            }
            let kind = conversion == "@" ? "@" : (conversion == "d" || conversion == "i" ? "d" : conversion)
            result.insert("\(position)\(kind)")
        }
        return result.sorted()
    }
}

/// A temporary bundle directory with compiled `.strings` tables for vi and en.
final class TemporaryAppBundle {
    let url: URL
    let bundle: Bundle

    /// `tables` maps table name -> language -> key -> value.
    init(tables: [String: [String: [String: String]]]) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellCoreTests-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (table, languages) in tables {
            for (language, strings) in languages {
                let lproj = url.appendingPathComponent("\(language).lproj", isDirectory: true)
                try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
                try data.write(to: lproj.appendingPathComponent("\(table).strings"))
            }
        }
        guard let bundle = Bundle(path: url.path) else { throw CocoaError(.fileNoSuchFile) }
        self.bundle = bundle
    }

    /// Bundle built from the shipped catalogs of `tables`.
    convenience init(catalogs tables: [StringTable]) throws {
        var compiled: [String: [String: [String: String]]] = [:]
        for table in tables {
            let catalog = try Catalog(table: table)
            var languages: [String: [String: String]] = [:]
            for (key, entry) in catalog.entries {
                for (language, value) in entry.values { languages[language, default: [:]][key] = value }
            }
            compiled[table.rawValue] = languages
        }
        try self.init(tables: compiled)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
