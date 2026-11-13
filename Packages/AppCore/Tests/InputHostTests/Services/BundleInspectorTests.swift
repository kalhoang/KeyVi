// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R510: the production bundle inspector on a synthetic bundle in a temporary directory (read-only lists).

import AppModel
import Foundation
import Testing

@testable import InputHost

private struct TemporaryBundle {
    let root: URL
    let bundle: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("w1e-bundle-\(UUID().uuidString)")
        bundle = root.appendingPathComponent("Sample.app")
        let contents = bundle.appendingPathComponent("Contents")
        let frameworks = contents.appendingPathComponent("Frameworks")
        let helpers = frameworks.appendingPathComponent("Sample Framework.framework/Versions/A/Helpers")
        let manager = FileManager.default
        try manager.createDirectory(
            at: helpers.appendingPathComponent("Sample Helper (Renderer).app/Contents"),
            withIntermediateDirectories: true)
        try manager.createDirectory(
            at: frameworks.appendingPathComponent("Other.framework"), withIntermediateDirectories: true)
        try manager.createDirectory(
            at: contents.appendingPathComponent("Resources/deep/er"), withIntermediateDirectories: true)
        try Data().write(to: contents.appendingPathComponent("Resources/deep/er/libxul.dylib"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample", "CFBundleVersion": "42", "LSRequiresIPhoneOS": true,
            "Numbers": [1, 2], "Nested": ["Key": "Value"], "Date": Date(timeIntervalSince1970: 0),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("FileSystemBundleInspector (PLT-R510)")
struct BundleInspectorTests {
    @Test func listsFrameworksHelpersFilesAndInfo() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        let inspector = FileSystemBundleInspector()
        #expect(inspector.frameworkNames(in: sample.bundle) == ["Other.framework", "Sample Framework.framework"])
        #expect(inspector.helperAppNames(in: sample.bundle) == ["Sample Helper (Renderer).app"])
        #expect(inspector.containsFile(named: "libxul.dylib", in: sample.bundle, maxDepth: 4))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: sample.bundle, maxDepth: 2))
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: sample.bundle, maxDepth: 8))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: sample.bundle, maxDepth: 0))
        let info = try #require(inspector.infoDictionary(of: sample.bundle))
        #expect(info["CFBundleIdentifier"] == .string("com.example.sample"))
        #expect(info["LSRequiresIPhoneOS"] == .bool(true))
        #expect(info["Numbers"] == .array([.number(1), .number(2)]))
        #expect(info["Nested"] == .object(["Key": .string("Value")]))
        #expect(info["Date"] == nil)
    }

    @Test func missingBundleGivesEmptyResults() {
        let inspector = FileSystemBundleInspector()
        let missing = URL(fileURLWithPath: "/nonexistent/w1e/Missing.app")
        #expect(inspector.frameworkNames(in: missing).isEmpty)
        #expect(inspector.helperAppNames(in: missing).isEmpty)
        #expect(!inspector.containsFile(named: "x", in: missing, maxDepth: 3))
        #expect(inspector.infoDictionary(of: missing) == nil)
    }
}
