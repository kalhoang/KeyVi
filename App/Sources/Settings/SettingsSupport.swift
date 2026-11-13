// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// Reads at most `maxBytes + 1` bytes off the main thread (a slow or network volume never freezes the window),
    /// so the importer can tell an oversized file from a full one.
    nonisolated static func readOffMain(_ url: URL, maxBytes: Int) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: maxBytes + 1) ?? Data()
        }.value
    }

    nonisolated static func writeOffMain(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: [.atomic]) }.value
    }
}

/// Installed app name and icon for a bundle key (bundle IDs come from the user's own data, PLT-R501). Each bundle
/// is resolved through LaunchServices once and then served from memory, so Table rows never hit NSWorkspace on a
/// re-render; the window clears the cache when it is shown, which picks up apps installed or removed meanwhile.
@MainActor
final class AppIdentityCache {
    private struct Entry {
        let installedName: String?
        let icon: NSImage?
    }

    private var entries: [BundleKey: Entry] = [:]

    /// The installed app's display name, else the matrix name, else the bundle key itself.
    func name(for bundle: BundleKey, matrixName: String?) -> String {
        entry(for: bundle).installedName ?? matrixName ?? bundle.rawValue
    }

    func icon(for bundle: BundleKey) -> NSImage? { entry(for: bundle).icon }

    func removeAll() { entries.removeAll() }

    private func entry(for bundle: BundleKey) -> Entry {
        if let cached = entries[bundle] { return cached }
        let resolved = Self.resolve(bundle)
        entries[bundle] = resolved
        return resolved
    }

    private static func resolve(_ bundle: BundleKey) -> Entry {
        guard !bundle.isExecutableHash,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle.rawValue)
        else { return Entry(installedName: nil, icon: nil) }
        let name = FileManager.default.displayName(atPath: url.path)
        return Entry(
            installedName: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
            icon: NSWorkspace.shared.icon(forFile: url.path))
    }
}
