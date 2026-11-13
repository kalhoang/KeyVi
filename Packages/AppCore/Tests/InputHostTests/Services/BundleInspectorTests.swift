// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R510, PLT-R384: the production bundle inspector on a synthetic bundle in a temporary directory (read-only
// lists). `containsFile` walks only the folder the fingerprinter names, bounded by depth, and never follows a
// symbolic link out of the bundle.

import AppModel
import Foundation
import Testing

@testable import InputHost

private struct TemporaryBundle {
    let root: URL
    let bundle: URL
    let contents: URL
    /// A folder next to the bundle, outside it.
    let outside: URL

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("w2g-bundle-\(UUID().uuidString)")
        bundle = root.appendingPathComponent("Sample.app")
        contents = bundle.appendingPathComponent("Contents")
        outside = root.appendingPathComponent("Outside")
        let frameworks = contents.appendingPathComponent("Frameworks")
        let helpers = frameworks.appendingPathComponent("Sample Framework.framework/Versions/A/Helpers")
        try manager.createDirectory(
            at: helpers.appendingPathComponent("Sample Helper (Renderer).app/Contents"),
            withIntermediateDirectories: true)
        try manager.createDirectory(
            at: frameworks.appendingPathComponent("Other.framework"), withIntermediateDirectories: true)
        try Self.touch(contents.appendingPathComponent("Resources/deep/er/libxul.dylib"))
        try Self.touch(contents.appendingPathComponent("MacOS/libxul.dylib"))
        try Self.touch(contents.appendingPathComponent("jbr/Contents/Home/lib/server/libjvm.dylib"))
        try Self.touch(outside.appendingPathComponent("Home/lib/server/libjvm.dylib"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample", "CFBundleVersion": "42", "LSRequiresIPhoneOS": true,
            "Numbers": [1, 2], "Nested": ["Key": "Value"], "Date": Date(timeIntervalSince1970: 0),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    static func touch(_ file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
    }

    func folder(_ relative: String) -> URL { contents.appendingPathComponent(relative, isDirectory: true) }

    func link(_ relative: String, to destination: URL) throws {
        let url = contents.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("FileSystemBundleInspector (PLT-R510)")
struct BundleInspectorTests {
    @Test func listsFrameworksHelpersAndInfo() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        let inspector = FileSystemBundleInspector()
        #expect(inspector.frameworkNames(in: sample.bundle) == ["Other.framework", "Sample Framework.framework"])
        #expect(inspector.helperAppNames(in: sample.bundle) == ["Sample Helper (Renderer).app"])
        let info = try #require(inspector.infoDictionary(of: sample.bundle))
        #expect(info["CFBundleIdentifier"] == .string("com.example.sample"))
        #expect(info["LSRequiresIPhoneOS"] == .bool(true))
        #expect(info["Numbers"] == .array([.number(1), .number(2)]))
        #expect(info["Nested"] == .object(["Key": .string("Value")]))
        #expect(info["Date"] == nil)
    }

    /// PLT-R510, PLT-R384: the URL is the folder to search, and depth counts from it (1 = directly inside).
    @Test func containsFileSearchesOnlyTheGivenFolderWithinTheDepthPLTR510() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        let inspector = FileSystemBundleInspector()
        #expect(inspector.containsFile(named: "libxul.dylib", in: sample.folder("MacOS"), maxDepth: 1))
        #expect(inspector.containsFile(named: "libjvm.dylib", in: sample.folder("jbr"), maxDepth: 5))
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: sample.folder("jbr"), maxDepth: 4))
        #expect(inspector.containsFile(named: "libxul.dylib", in: sample.folder("Resources"), maxDepth: 3))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: sample.folder("Resources"), maxDepth: 2))
        // Files elsewhere in the bundle are not found: only the named subtree is walked.
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: sample.folder("MacOS"), maxDepth: 6))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: sample.folder("jbr"), maxDepth: 6))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: sample.folder("MacOS"), maxDepth: 0))
        // A folder name is a match too: the walk compares entry names, it never opens files.
        #expect(inspector.containsFile(named: "server", in: sample.folder("jbr"), maxDepth: 4))
    }

    @Test func missingFolderIsFalse() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        let inspector = FileSystemBundleInspector()
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: sample.folder("runtime"), maxDepth: 6))
        // A file is not a folder to search.
        let file = sample.folder("MacOS").appendingPathComponent("libxul.dylib")
        #expect(!inspector.containsFile(named: "libxul.dylib", in: file, maxDepth: 6))
    }

    /// PLT-R384: a folder that is a link out of the bundle (a runtime installed elsewhere) is not searched, and
    /// the walk never descends into a linked folder inside the subtree.
    @Test func linksOutOfTheBundleAreNotFollowedPLTR384() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        try sample.link("runtime", to: sample.outside)
        try sample.link("PlugIns/jdk/Contents", to: sample.outside)
        let inspector = FileSystemBundleInspector()
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: sample.folder("runtime"), maxDepth: 6))
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: sample.folder("PlugIns"), maxDepth: 6))
    }

    /// A folder that is a link to another folder of the same bundle (framework `Versions/Current` style) is
    /// searched: it does not leave the bundle.
    @Test func aLinkedFolderInsideTheBundleIsSearched() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        try sample.link("Frameworks/Current", to: sample.folder("jbr/Contents/Home"))
        let inspector = FileSystemBundleInspector()
        #expect(inspector.containsFile(named: "libjvm.dylib", in: sample.folder("Frameworks/Current"), maxDepth: 3))
    }

    /// The walk stops after a fixed number of directory entries, so a huge folder stays cheap on the ax thread.
    @Test func theWalkIsBoundedByTheEntryLimit() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        for index in 0..<6 { try TemporaryBundle.touch(sample.folder("Wide").appendingPathComponent("f\(index)")) }
        try TemporaryBundle.touch(sample.folder("Wide/zz/target.dylib"))
        let bounded = FileSystemBundleInspector(entryLimit: 4)
        #expect(!bounded.containsFile(named: "target.dylib", in: sample.folder("Wide"), maxDepth: 2))
        #expect(FileSystemBundleInspector().containsFile(named: "target.dylib", in: sample.folder("Wide"), maxDepth: 2))
    }

    @Test func missingBundleGivesEmptyResults() {
        let inspector = FileSystemBundleInspector()
        let missing = URL(fileURLWithPath: "/nonexistent/w2g/Missing.app")
        #expect(inspector.frameworkNames(in: missing).isEmpty)
        #expect(inspector.helperAppNames(in: missing).isEmpty)
        #expect(!inspector.containsFile(named: "x", in: missing.appendingPathComponent("Contents/jbr"), maxDepth: 3))
        #expect(inspector.infoDictionary(of: missing) == nil)
    }

    /// Outside any bundle the folder itself is the boundary: a plain folder is searched, a link is not followed.
    @Test func aFolderOutsideABundleIsItsOwnBoundary() throws {
        let sample = try TemporaryBundle()
        defer { sample.remove() }
        let link = sample.root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sample.outside)
        let inspector = FileSystemBundleInspector()
        #expect(inspector.containsFile(named: "libjvm.dylib", in: sample.outside, maxDepth: 4))
        #expect(!inspector.containsFile(named: "libjvm.dylib", in: link, maxDepth: 4))
    }

    /// The bundle boundary is the folder that holds `Contents`; without one the folder itself is the boundary.
    @Test func bundleBoundary() {
        let jbr = URL(fileURLWithPath: "/Applications/Sample.app/Contents/jbr")
        #expect(FileSystemBundleInspector.bundleBoundary(of: jbr)?.path == "/Applications/Sample.app")
        let nested = URL(fileURLWithPath: "/Applications/Sample.app/Contents/Frameworks/X.framework/Contents/lib")
        #expect(FileSystemBundleInspector.bundleBoundary(of: nested)?.path == "/Applications/Sample.app")
        #expect(FileSystemBundleInspector.bundleBoundary(of: URL(fileURLWithPath: "/tmp/plain")) == nil)
        #expect(FileSystemBundleInspector.bundleBoundary(of: URL(fileURLWithPath: "/Contents/jbr")) == nil)
    }

    /// PLT-R384: a `Contents` folder above the bundle does not widen the boundary; the first `Contents` held by a
    /// folder with a bundle extension wins, and a plain `Contents` counts only when no bundle qualifies.
    @Test func aContentsFolderAboveTheBundleDoesNotWidenTheBoundaryPLTR384() {
        let above = URL(fileURLWithPath: "/Users/x/Contents/Apps/Foo.app/Contents/jbr")
        #expect(FileSystemBundleInspector.bundleBoundary(of: above)?.path == "/Users/x/Contents/Apps/Foo.app")
        let framework = URL(fileURLWithPath: "/Library/Contents/Frameworks/Bar.framework/Contents/lib")
        #expect(
            FileSystemBundleInspector.bundleBoundary(of: framework)?.path == "/Library/Contents/Frameworks/Bar.framework")
        let plain = URL(fileURLWithPath: "/Users/x/Plain/Contents/jbr")
        #expect(FileSystemBundleInspector.bundleBoundary(of: plain)?.path == "/Users/x/Plain")
    }

    /// The same rule on disk: a link from the bundle to a sibling folder under an outer `Contents` folder is not
    /// followed.
    @Test func aLinkToAFolderBesideTheBundleUnderAnOuterContentsFolderIsNotFollowed() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("w2g-outer-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let outer = root.appendingPathComponent("Contents")
        let bundleContents = outer.appendingPathComponent("Apps/Foo.app/Contents")
        let sibling = outer.appendingPathComponent("Shared")
        try TemporaryBundle.touch(sibling.appendingPathComponent("Home/lib/server/libjvm.dylib"))
        try manager.createDirectory(at: bundleContents, withIntermediateDirectories: true)
        let link = bundleContents.appendingPathComponent("jbr")
        try manager.createSymbolicLink(at: link, withDestinationURL: sibling)
        #expect(!FileSystemBundleInspector().containsFile(named: "libjvm.dylib", in: link, maxDepth: 6))
    }
}
