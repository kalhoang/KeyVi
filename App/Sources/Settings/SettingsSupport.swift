// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Small AppKit helpers of the Settings window: open and save panels (files only where the user picks them,
// PRD-R69), bounded reads of untrusted files (PLT-R912) and app names and icons for the Apps pane (PRD-R34).

import AppKit
import AppModel
import Foundation
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    /// PRD-R32: own JSON export, TAB-separated text, CSV, Text Replacements property list.
    static let macroTypes: [UTType] = [.json, .plainText, .tabSeparatedText, .commaSeparatedText, .propertyList]

    static func open(types: [UTType], completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
    }

    static func save(
        suggestedName: String, completion: @escaping @MainActor (URL) -> Void,
        cancelled: @escaping @MainActor () -> Void = {}
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return cancelled() }
                completion(url)
            }
        }
    }

    /// Reads at most `maxBytes + 1` bytes, so the importer can tell an oversized file from a full one.
    nonisolated static func read(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes + 1) ?? Data()
    }

    nonisolated static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

/// Installed app name and icon for a bundle key (bundle IDs come from the user's own data, PLT-R501).
@MainActor
enum AppIdentity {
    static func url(for bundle: BundleKey) -> URL? {
        guard !bundle.isExecutableHash else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle.rawValue)
    }

    /// The installed app's display name, else the matrix name, else the bundle key itself.
    static func name(for bundle: BundleKey, matrixName: String?) -> String {
        if let url = url(for: bundle) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return matrixName ?? bundle.rawValue
    }

    static func icon(for bundle: BundleKey) -> NSImage? {
        url(for: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
