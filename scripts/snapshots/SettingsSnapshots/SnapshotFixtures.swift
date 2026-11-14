// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fixtures of the Settings snapshot bundle (W8-D): a settings store in a temporary folder with sample data, test
// doubles for the updater and the login item, and the window model built from them. Nothing here starts InputHost
// or the app environment, creates an event tap, requests or checks a permission or posts an event; the bundle's
// own resources (catalogs, assets, matrix, pane names) are the only files read besides the temporary store.

import AppKit
import AppModel
import CompatRules
import Foundation
import SettingsStore
import ShellCore
import TestSupport

/// Locates the snapshot bundle (its catalogs, assets and Info.plist).
final class SnapshotBundleMarker {}

enum SnapshotFixtures {
    static var bundle: Bundle { Bundle(for: SnapshotBundleMarker.self) }

    /// A store in a new temporary folder with sample word lists, learned words, macros and app modes, so the panes
    /// show their lists the way a user's would look. App rows use apps of the bundled matrix (no bundle ID here).
    static func store(matrix: MatrixDocument?) async throws -> SettingsStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SettingsStore(
            location: StorageLocation(directory: folder), fileSystem: LocalFileSystem(), wallClock: SystemWallClock(),
            writtenBy: "snapshot", queue: DispatchQueue(label: "settings-snapshots.utility", qos: .utility),
            launchGuard: LaunchGuard(store: InMemoryKeyValueStore()), onChange: { _ in })
        _ = await store.load()
        let apps = sampleApps(matrix)
        await store.updateSettings { settings in
            settings.keepAsTyped = ["wifi", "user", "email"]
            settings.keepVietnamese = ["vieetj"]
            if let app = apps.first {
                settings.learnedWords = [LearnedWord(list: .keepAsTyped, raw: "text", app: app)]
            }
        }
        await store.recordAppModes(
            AppModesDocument(
                globalMode: .vietnamese,
                apps: apps.enumerated().map { index, bundle in
                    AppModeEntry(bundle: bundle, mode: index.isMultiple(of: 2) ? .vietnamese : .english)
                }))
        if apps.count > 2 {
            await store.setAppRule(.alwaysEnglish, for: apps[1])
            await store.setAppRule(.alwaysVietnamese, for: apps[2])
        }
        await store.replaceMacros([
            StoredMacro(trigger: "ko", expansion: "không"),
            StoredMacro(trigger: "dc", expansion: "được"),
            StoredMacro(trigger: "vn", expansion: "Việt Nam"),
            StoredMacro(trigger: "@@", expansion: "ten@example.com", enabled: false),
        ])
        return store
    }

    /// The first apps of the bundled matrix that macOS ships, plus a few others, so the rows have real icons.
    static func sampleApps(_ matrix: MatrixDocument?) -> [BundleKey] {
        Array((matrix?.entries ?? []).map(\.bundleId).prefix(5))
    }

    static func matrix() -> MatrixDocument? {
        bundle.url(forResource: "matrix", withExtension: "json").flatMap(MatrixLoader.load(contentsOf:))
    }

    static func paneNames(systemLanguage: String) -> SystemPaneNames? {
        guard let url = bundle.url(forResource: "SystemPanes", withExtension: "json"),
            let data = try? Data(contentsOf: url), let table = try? SystemPaneTable(resource: data)
        else { return nil }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let running = LooseVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        return running.map { table.names(macOS: $0, systemLanguage: systemLanguage) }
    }
}

/// The Sparkle wrapper's double: no network, no Sparkle.
final class SnapshotUpdater: UpdaterControlling {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true
    var channel = UpdateChannelSelection.stable
    func checkForUpdates() {}
}

/// The login item double: reports the status it was given and never touches `SMAppService`.
struct SnapshotLoginItem: LoginItemService {
    let status: LoginItemStatus
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
