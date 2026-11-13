// SPDX-License-Identifier: LicenseRef-App-Pending
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
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
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

    public init(testHostBundleID: BundleKey?, appUnderTestBundleID: BundleKey?, pagesDirectory: URL) {
        self.testHostBundleID = testHostBundleID
        self.appUnderTestBundleID = appUnderTestBundleID
        self.pagesDirectory = pagesDirectory
    }

    /// Targets of the checkout at `repository`. `brandEnvironment` is the text of scripts/brand.env (nil when
    /// missing); explicit values (command-line options) win over the brand file.
    public static func resolve(
        repository: URL, brandEnvironment: String?, testHost: String? = nil, appUnderTest: String? = nil
    ) -> HarnessTargets {
        let brand = brandEnvironment.map(BrandEnvironment.parse) ?? [:]
        let developmentID = brand["APP_BUNDLE_ID_DEV"].flatMap { $0.isEmpty ? nil : $0 }
        return HarnessTargets(
            testHostBundleID: (testHost ?? developmentID.map { $0 + ".testhost" }).flatMap(BundleKey.init(rawValue:)),
            appUnderTestBundleID: (appUnderTest ?? developmentID).flatMap(BundleKey.init(rawValue:)),
            pagesDirectory: repository.appendingPathComponent(pagesPath, isDirectory: true))
    }

    /// The real bundle ID for a scenario target or `launch` value; `nil` when the alias cannot be resolved.
    public func resolve(_ key: BundleKey) -> BundleKey? {
        key.rawValue == Self.testHostAlias ? testHostBundleID : key
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
}
