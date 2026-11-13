// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import TestSupport
import Testing

@testable import SettingsStore

@Suite struct LegacyStorageTests {
    private let support = URL(fileURLWithPath: "/Users/t/Library/Application Support", isDirectory: true)
    private let logs = URL(fileURLWithPath: "/Users/t/Library/Logs", isDirectory: true)

    private func folder(_ base: URL, _ name: String) -> URL { base.appendingPathComponent(name, isDirectory: true) }

    @Test func movesTheNewestLegacyFolderInBothBasesKeeping0700() throws {
        let fs = InMemoryFileSystem()
        for base in [support, logs] {
            try fs.createDirectory(at: folder(base, "Older Name"), permissions: .ownerOnlyDirectory)
            try fs.createDirectory(at: folder(base, "Old Name"), permissions: .ownerOnlyDirectory)
        }
        let results = LegacyStorageMigrator.migrate(
            current: "New Name", legacyNames: ["Old Name", "Older Name"], bases: [support, logs], fileSystem: fs)
        #expect(results == [.moved(from: "Old Name"), .moved(from: "Old Name")])
        for base in [support, logs] {
            #expect(fs.nodes[folder(base, "New Name").path]?.permissions == .ownerOnlyDirectory)
            #expect(fs.nodes[folder(base, "New Name").path]?.data == nil)
            #expect(!fs.fileExists(at: folder(base, "Old Name")))
            #expect(fs.fileExists(at: folder(base, "Older Name")))
        }
    }

    @Test func bothExistLeavesEverythingUntouched() throws {
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: folder(support, "New Name"), permissions: .ownerOnlyDirectory)
        try fs.createDirectory(at: folder(support, "Old Name"), permissions: .ownerOnlyDirectory)
        let before = fs.nodes
        let results = LegacyStorageMigrator.migrate(
            current: "New Name", legacyNames: ["Old Name"], bases: [support], fileSystem: fs)
        #expect(results == [.skippedBothExist(legacy: "Old Name")])
        #expect(fs.nodes == before)
    }

    @Test func noLegacyFolderIsNotNeeded() throws {
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: folder(logs, "New Name"), permissions: .ownerOnlyDirectory)
        let results = LegacyStorageMigrator.migrate(
            current: "New Name", legacyNames: ["Old Name"], bases: [support, logs], fileSystem: fs)
        #expect(results == [.notNeeded, .notNeeded])
        #expect(
            LegacyStorageMigrator.migrate(current: "New Name", legacyNames: [], bases: [support], fileSystem: fs) == [
                .notNeeded
            ])
    }

    @Test func unsafeNamesAreIgnored() throws {
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: URL(fileURLWithPath: "/Users/t/Library"), permissions: .ownerOnlyDirectory)
        let before = fs.nodes
        let names = ["", ".", "..", "../Library", "a/b", "New Name"]
        let results = LegacyStorageMigrator.migrate(
            current: "New Name", legacyNames: names, bases: [support], fileSystem: fs)
        #expect(results == [.notNeeded])
        #expect(
            LegacyStorageMigrator.migrate(current: "../x", legacyNames: ["Old"], bases: [support], fileSystem: fs) == [
                .notNeeded
            ])
        #expect(fs.nodes == before)
    }

    @Test func aFailedMoveIsReported() throws {
        let memory = InMemoryFileSystem()
        try memory.createDirectory(at: folder(support, "Old Name"), permissions: .ownerOnlyDirectory)
        let spy = SpyFileSystem(memory)
        spy.failAll(.moveItem)
        let results = LegacyStorageMigrator.migrate(
            current: "New Name", legacyNames: ["Old Name"], bases: [support], fileSystem: spy)
        #expect(results == [.failed(.ioFailure(path: folder(support, "Old Name").path, errno: EIO))])
        #expect(memory.fileExists(at: folder(support, "Old Name")))
    }

    /// The real file system moves the folder with its contents and mode (rename(2)).
    @Test func movesARealFolderWithItsContents() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("w1b-legacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let fs = LocalFileSystem()
        try fs.createDirectory(at: folder(base, "Old Name"), permissions: .ownerOnlyDirectory)
        try fs.writeAtomically(
            Data("{}".utf8), to: folder(base, "Old Name").appendingPathComponent("settings.json"),
            permissions: .ownerOnlyFile)
        let results = LegacyStorageMigrator.migrate(
            current: "New Name", legacyNames: ["Old Name"], bases: [base], fileSystem: fs)
        #expect(results == [.moved(from: "Old Name")])
        let moved = folder(base, "New Name")
        #expect(try fs.attributes(at: moved).permissions == .ownerOnlyDirectory)
        #expect(try fs.readData(at: moved.appendingPathComponent("settings.json"), maxBytes: 10) == Data("{}".utf8))
        #expect(!fs.fileExists(at: folder(base, "Old Name")))
    }
}
