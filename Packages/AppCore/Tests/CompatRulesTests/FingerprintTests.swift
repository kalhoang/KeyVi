// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import TestSupport
import Testing

@testable import CompatRules

@Suite struct FingerprintTests {
    typealias FakeBundle = ScriptedBundleInspector.FakeBundle

    static let app = URL(fileURLWithPath: "/Applications/Under Test.app")

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
        .init(label: "gecko", bundle: FakeBundle(files: ["libxul.dylib": 2]), expected: .gecko),
        .init(label: "gecko too deep", bundle: FakeBundle(files: ["libxul.dylib": 9]), expected: .native),
        .init(label: "jvm", bundle: FakeBundle(files: ["libjvm.dylib": 6]), expected: .jvm),
        .init(label: "qt", bundle: FakeBundle(frameworks: ["QtCore.framework", "QtGui.framework"]), expected: .qt),
        .init(
            label: "ios by platform",
            bundle: FakeBundle(info: ["CFBundleSupportedPlatforms": .array([.string("iPhoneOS")])]), expected: .ios),
        .init(
            label: "ios by LSRequiresIPhoneOS", bundle: FakeBundle(info: ["LSRequiresIPhoneOS": .bool(true)]),
            expected: .ios),
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
                files: ["libxul.dylib": 1, "libjvm.dylib": 1]), expected: .chromium),
        .init(
            label: "jvm beats qt", bundle: FakeBundle(frameworks: ["QtCore.framework"], files: ["libjvm.dylib": 3]),
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
        inspector.set(FakeBundle(files: ["libjvm.dylib": 4], info: ["CFBundleVersion": .string("2")]), at: Self.app)
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
