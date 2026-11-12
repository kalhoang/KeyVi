// SPDX-License-Identifier: LicenseRef-App-Pending
import Foundation
import Testing
import TestSupport
@testable import AppModel

@Suite struct IdentifierTests {
    @Test func bundleKeyRejectsFreeText() {
        #expect(BundleKey(rawValue: "hello world") == nil)
        #expect(BundleKey(rawValue: "") == nil)
        #expect(BundleKey(rawValue: String(repeating: "a", count: 256)) == nil)
        #expect(BundleKey(rawValue: "vn.example.App-1") != nil)
    }

    @Test func executableHashKey() {  // PLT-R393
        let hex = String(repeating: "ab", count: 32)
        #expect(BundleKey.executable(sha256Hex: hex)?.isExecutableHash == true)
        #expect(BundleKey.executable(sha256Hex: "abc") == nil)
    }

    @Test func ruleIDSegments() {
        #expect(RuleID(rawValue: "terminal.default") != nil)
        #expect(RuleID(rawValue: "user.ignore.3")?.isUserOverride == true)
        #expect(RuleID(rawValue: "bad..id") == nil)
        #expect(RuleID(rawValue: "has space") == nil)
    }
}

@Suite struct VersionTests {
    @Test func comparesComponentWise() throws {
        let a = try #require(LooseVersion("155.0.7000.12"))
        let b = try #require(LooseVersion("155.1"))
        #expect(a < b)
        #expect(LooseVersion("27.1") == LooseVersion("27.1.0"))
        #expect(LooseVersion("1.0.0-beta.2")?.components == [1, 0, 0])
        #expect(LooseVersion("beta") == nil)
    }

    @Test func rangeIsInclusive() throws {
        let range = VersionRange(min: LooseVersion("15.0"), max: LooseVersion("26.99"))
        #expect(range.contains(try #require(LooseVersion("15.0"))))
        #expect(!range.contains(try #require(LooseVersion("27.0"))))
    }
}

@Suite struct HotkeyCodingTests {
    @Test func roundTripsDocumentedShapes() throws {
        let bindings: [HotkeyBinding] = [
            .modifierTap(.controlShift), .keyCombo(modifiers: [.command, .option], keyCode: KeyCode(rawValue: 40)),
            .key(.escape),
        ]
        for binding in bindings {
            let data = try JSONEncoder().encode(binding)
            #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == binding)
        }
        let json = #"{"type":"modifierTap","chord":"controlShift"}"#
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8)) == .defaultToggle)
    }

    @Test func bareKeyOnlyForRestore() {  // PRD-R15, PRD-R18
        #expect(!HotkeyBinding.key(.escape).isAllowed(for: .toggleMode))
        #expect(HotkeyBinding.key(.escape).isAllowed(for: .restoreLastWord))
    }
}

@Suite struct FileSystemTests {
    @Test func inMemoryAtomicWriteAndFailureInjection() throws {
        let fs = InMemoryFileSystem()
        let url = URL(fileURLWithPath: "/tmp/settings.json")
        try fs.writeAtomically(Data("{}".utf8), to: url, permissions: .ownerOnlyFile)
        #expect(try fs.readData(at: url, maxBytes: 10) == Data("{}".utf8))
        #expect(throws: FileSystemError.self) { try fs.readData(at: url, maxBytes: 1) }
        fs.failNextWrite(to: url)
        #expect(throws: FileSystemError.self) { try fs.writeAtomically(Data(), to: url, permissions: .ownerOnlyFile) }
        #expect(try fs.attributes(at: url).permissions == .ownerOnlyFile)
    }

    @Test func localAtomicWriteSetsPermissions() throws {
        let fs = LocalFileSystem()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appcore-\(UUID().uuidString)")
        try fs.createDirectory(at: dir, permissions: .ownerOnlyDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.json")
        try fs.writeAtomically(Data("1".utf8), to: url, permissions: .ownerOnlyFile)
        try fs.writeAtomically(Data("2".utf8), to: url, permissions: .ownerOnlyFile)
        #expect(try fs.readData(at: url, maxBytes: 10) == Data("2".utf8))
        #expect(try fs.attributes(at: url).permissions == .ownerOnlyFile)
        #expect(try fs.attributes(at: dir).permissions == .ownerOnlyDirectory)
    }
}
