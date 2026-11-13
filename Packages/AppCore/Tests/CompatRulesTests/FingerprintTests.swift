// SPDX-License-Identifier: GPL-3.0-or-later

import AppModel
import Foundation
import TestSupport
import Testing

@testable import CompatRules

@Suite struct FingerprintTests {
    typealias FakeBundle = ScriptedBundleInspector.FakeBundle

    static let app = URL(fileURLWithPath: "/Applications/Under Test.app")
    static let jbrJVM = "Contents/jbr/Contents/Home/lib/server/libjvm.dylib"

    struct EngineCase: Sendable, CustomTestStringConvertible {
        let label: String
        let bundle: FakeBundle
        let expected: EngineFingerprint
        var testDescription: String { label }
    }

    static let engineCases: [EngineCase] = [
        .init(
            label: "electron",
            bundle: FakeBundle(frameworks: ["Electron Framework.framework"], helpers: ["Code Helper (Renderer).app"]),
            expected: .electron),
        .init(label: "cef", bundle: FakeBundle(frameworks: ["Chromium Embedded Framework.framework"]), expected: .cef),
        .init(
            label: "chromium",
            bundle: FakeBundle(frameworks: ["Helium Framework.framework"], helpers: ["Helium Helper (Renderer).app"]),
            expected: .chromium),
        .init(
            label: "framework without renderer helper is not chromium",
            bundle: FakeBundle(frameworks: ["Sparkle Framework.framework"], helpers: ["Updater.app"]), expected: .native
        ),
        .init(label: "gecko", bundle: FakeBundle(files: ["Contents/MacOS/libxul.dylib"]), expected: .gecko),
        .init(
            label: "gecko outside the searched folders",
            bundle: FakeBundle(files: ["Contents/Resources/extra/libxul.dylib"]), expected: .native),
        .init(label: "jvm (JetBrains runtime)", bundle: FakeBundle(files: [jbrJVM]), expected: .jvm),
        .init(
            label: "jvm (jpackage runtime)",
            bundle: FakeBundle(files: ["Contents/runtime/Contents/Home/lib/server/libjvm.dylib"]), expected: .jvm),
        .init(
            label: "jvm (bundled JDK plug-in)",
            bundle: FakeBundle(files: ["Contents/PlugIns/jdk-21.jdk/Contents/Home/lib/server/libjvm.dylib"]),
            expected: .jvm),
        .init(
            label: "jvm too deep below a Java root",
            bundle: FakeBundle(files: ["Contents/Resources/a/b/c/d/e/f/libjvm.dylib"]), expected: .native),
        .init(
            label: "jvm outside the Java roots is not searched",
            bundle: FakeBundle(files: ["Contents/Developer/Tools/jre/lib/server/libjvm.dylib"]), expected: .native),
        .init(label: "qt", bundle: FakeBundle(frameworks: ["QtCore.framework", "QtGui.framework"]), expected: .qt),
        .init(
            label: "ios by platform",
            bundle: FakeBundle(info: ["CFBundleSupportedPlatforms": .array([.string("iPhoneOS")])]), expected: .ios),
        .init(
            label: "ios by LSRequiresIPhoneOS", bundle: FakeBundle(info: ["LSRequiresIPhoneOS": .bool(true)]),
            expected: .ios),
        .init(
            label: "catalyst keeping LSRequiresIPhoneOS from its iOS target",
            bundle: FakeBundle(info: [
                "CFBundleSupportedPlatforms": .array([.string("MacOSX")]), "LSRequiresIPhoneOS": .bool(true),
            ]), expected: .catalyst),
        .init(
            label: "catalyst",
            bundle: FakeBundle(info: [
                "CFBundleSupportedPlatforms": .array([.string("MacOSX")]), "UIDeviceFamily": .array([.number(6)]),
            ]), expected: .catalyst),
        .init(
            label: "native",
            bundle: FakeBundle(
                frameworks: ["Sparkle.framework"], info: ["CFBundleSupportedPlatforms": .array([.string("MacOSX")])]),
            expected: .native),
        .init(
            label: "electron beats chromium markers",
            bundle: FakeBundle(
                frameworks: ["Electron Framework.framework", "X Framework.framework"],
                helpers: ["X Helper (Renderer).app"]), expected: .electron),
        .init(
            label: "chromium beats gecko and jvm",
            bundle: FakeBundle(
                frameworks: ["X Framework.framework"], helpers: ["X Helper (Renderer).app"],
                files: ["Contents/MacOS/libxul.dylib", jbrJVM]), expected: .chromium),
        .init(
            label: "jvm beats qt", bundle: FakeBundle(frameworks: ["QtCore.framework"], files: [jbrJVM]),
            expected: .jvm),
        .init(
            label: "qt beats ios",
            bundle: FakeBundle(frameworks: ["QtCore.framework"], info: ["LSRequiresIPhoneOS": .bool(true)]),
            expected: .qt),
    ]

    /// PLT-R510 heuristics in their documented order.
    @Test(arguments: engineCases)
    func heuristic(_ testCase: EngineCase) {
        let inspector = ScriptedBundleInspector(bundles: [Self.app: testCase.bundle])
        let fingerprinter = EngineFingerprinter(inspector: inspector, webkitBrowsers: [])
        #expect(
            fingerprinter.fingerprint(bundleURL: Self.app, bundle: bundleKey("com.example.app")) == testCase.expected)
    }

    /// PLT-R510, PLT-R384: the first fingerprint of a large bundle (an IDE, a game) runs on the ax thread, so
    /// file searches stay in the folders where the library lives and never walk the whole bundle.
    @Test func fileSearchesAreBoundedToKnownFoldersPLTR510() {
        let inspector = ScriptedBundleInspector(bundles: [Self.app: FakeBundle()])
        let fingerprinter = EngineFingerprinter(inspector: inspector, webkitBrowsers: [])
        #expect(fingerprinter.fingerprint(bundleURL: Self.app, bundle: nil) == .native)
        let searches = inspector.fileSearches
        #expect(Set(searches.map(\.name)) == ["libxul.dylib", "libjvm.dylib"])
        for search in searches {
            #expect(search.directory.hasPrefix("Contents/"), "searched \(search.directory)")
            #expect(!["", "Contents", "Contents/Developer"].contains(search.directory))
            #expect(search.maxDepth <= 6)
        }
    }

    @Test func webkitBrowserComesFromTheRulesGroupAndWinsOverEverything() {
        let safari = bundleKey("com.apple.Safari")
        let inspector = ScriptedBundleInspector(bundles: [
            Self.app: FakeBundle(frameworks: ["Electron Framework.framework"])
        ])
        let fingerprinter = EngineFingerprinter(inspector: inspector, webkitBrowsers: [safari])
        #expect(fingerprinter.fingerprint(bundleURL: Self.app, bundle: safari) == .webkitBrowser)
        #expect(fingerprinter.fingerprint(bundleURL: Self.app, bundle: nil) == .electron)
        #expect(fingerprinter.fingerprint(bundleURL: Self.app, bundle: bundleKey("com.example.other")) == .electron)
    }

    @Test func missingBundleIsNative() {
        let fingerprinter = EngineFingerprinter(inspector: ScriptedBundleInspector(), webkitBrowsers: [])
        #expect(fingerprinter.fingerprint(bundleURL: Self.app, bundle: nil) == .native)
    }

    /// Acceptance (section 5): a Chromium browser unknown to the rules gets the `engines: ["chromium"]` rule.
    @Test func unknownChromiumBrowserGetsTheChromiumRule() throws {
        let rules = try Build.seededRuleSet()
        let unknownBrowser = bundleKey("com.example.chromiumfork")
        #expect(!(try LoadingTests.seededBundleIDs()).contains(unknownBrowser.rawValue))
        let inspector = ScriptedBundleInspector(bundles: [
            Self.app: FakeBundle(frameworks: ["Helium Framework.framework"], helpers: ["Helium Helper (Renderer).app"])
        ])
        let engine = EngineFingerprinter(inspector: inspector, webkitBrowsers: rules.webkitBrowsers)
            .fingerprint(bundleURL: Self.app, bundle: unknownBrowser)
        #expect(engine == .chromium)
        let addressBar = rules.resolve(
            Build.context(
                bundle: unknownBrowser.rawValue, engine: engine, role: "AXTextField", ancestorRoles: ["AXToolbar"]))
        #expect(addressBar.rule == ruleID("browser.chromium.addressBar"))
        #expect(addressBar.params.inlineCompletion == .axSelectionThenPlaceholder)
        #expect(addressBar.features.autoCapitalize == false)
        let page = rules.resolve(Build.context(bundle: unknownBrowser.rawValue, engine: engine, role: "AXTextArea"))
        #expect(page.rule == nil)
        #expect(page.requireTextFocus == .never)
    }

    /// PLT-R510: one inspection per (bundle path, CFBundleVersion); an update is fingerprinted again.
    @Test func cacheInspectsOncePerBundleVersion() {
        let electron = FakeBundle(frameworks: ["Electron Framework.framework"], info: ["CFBundleVersion": .string("1")])
        let inspector = ScriptedBundleInspector(bundles: [Self.app: electron])
        var cache = EngineFingerprintCache(fingerprinter: EngineFingerprinter(inspector: inspector, webkitBrowsers: []))
        #expect(cache.fingerprint(bundleURL: Self.app, bundle: nil) == .electron)
        let afterFirst = inspector.inspectionCount
        #expect(cache.fingerprint(bundleURL: Self.app, bundle: nil) == .electron)
        #expect(inspector.inspectionCount == afterFirst)
        inspector.set(FakeBundle(files: [Self.jbrJVM], info: ["CFBundleVersion": .string("2")]), at: Self.app)
        #expect(cache.fingerprint(bundleURL: Self.app, bundle: nil) == .jvm)
        #expect(inspector.inspectionCount > afterFirst)
        #expect(cache.count == 2)
    }

    @Test func cacheStaysBounded() {
        let inspector = ScriptedBundleInspector()
        var cache = EngineFingerprintCache(
            fingerprinter: EngineFingerprinter(inspector: inspector, webkitBrowsers: []), capacity: 2)
        for index in 0..<5 {
            _ = cache.fingerprint(
                bundleURL: URL(fileURLWithPath: "/Applications/App" + String(index) + ".app"), bundle: nil)
        }
        #expect(cache.count <= 2)
    }
}
