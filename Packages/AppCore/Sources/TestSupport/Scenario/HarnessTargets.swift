// SPDX-License-Identifier: GPL-3.0-or-later
//
// Brand-neutral scenario targets. Scenario files never spell the product's own bundle IDs (CLAUDE.md brand
// rule): TestHost scenarios use the reserved alias `local.testhost`, resolved at run time from
// scripts/brand.env (`APP_BUNDLE_ID_DEV` + `.testhost`, as project.yml builds it), and setup values may use
// `{pages}` for the file URL of TestHost/Resources/Pages, so the same scenario runs from any checkout.

public import AppModel
public import Foundation

public enum BrandEnvironment {
    /// `KEY="value"` / `KEY=value` lines of scripts/brand.env; comments and blank lines are skipped.
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}

public struct HarnessTargets: Sendable, Hashable {
    /// Reserved `targetBundleId` / `launch` value meaning "the TestHost app of this checkout".
    public static let testHostAlias = "local.testhost"
    /// Placeholder in setup values for the local test pages directory as a `file://` URL (no trailing slash).
    public static let pagesPlaceholder = "{pages}"
    /// Relative location of the local test pages inside the repository.
    public static let pagesPath = "TestHost/Resources/Pages"

    public var testHostBundleID: BundleKey?
    /// Bundle ID of the build under test, for resource sampling (C1, C2, M1, M2).
    public var appUnderTestBundleID: BundleKey?
    public var pagesDirectory: URL
    /// Folder of the app under test below Application Support and Logs: the display name when it is ASCII, else
    /// the slug (PLT-R903, the rule of `Brand.folderName`). Nil without scripts/brand.env.
    public var storageFolderName: String?
    /// The site host, the one host the egress test allows in production (PLT-R906).
    public var siteHost: String?
    /// Apps whose app menu has a "Secure Keyboard Entry" item: the `secureInputHints` of compat/rules.json whose
    /// hint key ends in `.secureKeyboardEntry` (PLT-R398C). The harness toggles it there on the runner.
    public var secureKeyboardEntryApps: Set<BundleKey>

    public init(
        testHostBundleID: BundleKey?, appUnderTestBundleID: BundleKey?, pagesDirectory: URL,
        storageFolderName: String? = nil, siteHost: String? = nil, secureKeyboardEntryApps: Set<BundleKey> = []
    ) {
        self.testHostBundleID = testHostBundleID
        self.appUnderTestBundleID = appUnderTestBundleID
        self.pagesDirectory = pagesDirectory
        self.storageFolderName = storageFolderName
        self.siteHost = siteHost
        self.secureKeyboardEntryApps = secureKeyboardEntryApps
    }

    /// Hint-key suffix of the apps with a Secure Keyboard Entry menu item.
    public static let secureKeyboardEntryHintSuffix = ".secureKeyboardEntry"

    /// `secureInputHints[].bundleId` whose hint key ends in `.secureKeyboardEntry`.
    public static func secureKeyboardEntryApps(rulesData: Data) -> Set<BundleKey> {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: rulesData),
            case .array(let hints)? = document["secureInputHints"]
        else { return [] }
        return Set(
            hints.compactMap { hint in
                guard hint["hintKey"]?.stringValue?.hasSuffix(secureKeyboardEntryHintSuffix) == true else { return nil }
                return hint["bundleId"]?.stringValue.flatMap(BundleKey.init(rawValue:))
            })
    }

    /// Targets of the checkout at `repository`. `brandEnvironment` is the text of scripts/brand.env (nil when
    /// missing); explicit values (command-line options) win over the brand file.
    public static func resolve(
        repository: URL, brandEnvironment: String?, testHost: String? = nil, appUnderTest: String? = nil
    ) -> HarnessTargets {
        let brand = (brandEnvironment.map(BrandEnvironment.parse) ?? [:]).filter { !$0.value.isEmpty }
        let developmentID = brand["APP_BUNDLE_ID_DEV"]
        let folder = brand["APP_DISPLAY_NAME"].map { name in
            name.allSatisfy(\.isASCII) ? name : (brand["APP_SLUG"] ?? name)
        }
        return HarnessTargets(
            testHostBundleID: (testHost ?? developmentID.map { $0 + ".testhost" }).flatMap(BundleKey.init(rawValue:)),
            appUnderTestBundleID: (appUnderTest ?? developmentID).flatMap(BundleKey.init(rawValue:)),
            pagesDirectory: repository.appendingPathComponent(pagesPath, isDirectory: true),
            storageFolderName: folder, siteHost: brand["APP_SITE_HOST"])
    }

    /// The real bundle ID for a scenario target or `launch` value; `nil` when the alias cannot be resolved.
    public func resolve(_ key: BundleKey) -> BundleKey? {
        key.rawValue == Self.testHostAlias ? testHostBundleID : key
    }

    /// The scenario with an aliased `expect.holderBundleId` replaced by the real bundle ID, so it compares with
    /// what the app under test reports (PLT-R398B: TestHost holds secure input).
    public func resolvingExpectation(of scenario: Scenario) -> Scenario {
        var resolved = scenario
        if let holder = scenario.expect.holderBundleId { resolved.expect.holderBundleId = resolve(holder) ?? holder }
        return resolved
    }

    /// Expands `{pages}` in a setup value.
    public func expand(_ value: String) -> String {
        guard value.contains(Self.pagesPlaceholder) else { return value }
        var base = pagesDirectory.standardizedFileURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return value.replacingOccurrences(of: Self.pagesPlaceholder, with: base)
    }
}

/// Accessibility identifiers of TestHost controls the harness drives (TestHost/Sources defines the same
/// literals; TestHostSourcesTests keeps them in sync).
public enum TestHostControls {
    /// Checkbox that holds secure event input while on (PLT-R398B scenarios: TestHost is the holder).
    public static let secureInputToggle = "testhost.secureInput.toggle"
    /// Multi-line native field the C2 measurement types into (TestHostField.nativeTextView).
    public static let typingField = "testhost.native.textView"
    /// Button that clears every field of both windows (pressed before each TestHost scenario).
    public static let resetFields = "testhost.resetFields"
    /// Native field of the main window and of the second window (per-app rule switching, QA-R11, and the
    /// workload of the T2, T3, T5 and T6 measurement).
    public static let mainTextField = "testhost.native.textField"
    public static let secondTextField = "testhost.second.textField"
    /// Address bar with inline completion: the T3 (axSelection) part of the measured workload.
    public static let addressBar = "testhost.sim.addressBar"
}
