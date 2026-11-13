// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Scripted app bundles for engine fingerprinting tests (PLT-R510), with inspection counting for cache tests.
// Distinct from the Host fakes' FakeBundleInspector (W1-E). Usable by any test that needs a
// fingerprint without touching the file system.

public import AppModel
public import CompatRules
public import Foundation
internal import Synchronization

public final class ScriptedBundleInspector: BundleInspector, Sendable {
    /// What a bundle looks like from the outside: framework and helper names, files with their depth below
    /// `Contents`, and the Info.plist.
    public struct FakeBundle: Sendable, Hashable {
        public var frameworks: [String]
        public var helpers: [String]
        public var files: [String: Int]
        public var info: [String: JSONValue]?

        public init(
            frameworks: [String] = [], helpers: [String] = [], files: [String: Int] = [:],
            info: [String: JSONValue]? = nil
        ) {
            self.frameworks = frameworks
            self.helpers = helpers
            self.files = files
            self.info = info
        }
    }

    private let bundles: Mutex<[String: FakeBundle]>
    private let calls = Mutex<Int>(0)

    public init(bundles: [URL: FakeBundle] = [:]) {
        self.bundles = Mutex(Dictionary(uniqueKeysWithValues: bundles.map { ($0.key.path, $0.value) }))
    }

    /// Replaces a bundle, for example to simulate an app update with a new `CFBundleVersion`.
    public func set(_ bundle: FakeBundle, at url: URL) { bundles.withLock { $0[url.path] = bundle } }

    /// Number of inspection calls other than `infoDictionary` (which the cache reads for the version key).
    public var inspectionCount: Int { calls.withLock { $0 } }

    private func bundle(at url: URL, counted: Bool = true) -> FakeBundle? {
        if counted { calls.withLock { $0 += 1 } }
        return bundles.withLock { $0[url.path] }
    }

    public func frameworkNames(in bundle: URL) -> [String] { self.bundle(at: bundle)?.frameworks ?? [] }
    public func helperAppNames(in bundle: URL) -> [String] { self.bundle(at: bundle)?.helpers ?? [] }

    public func containsFile(named name: String, in bundle: URL, maxDepth: Int) -> Bool {
        guard let depth = self.bundle(at: bundle)?.files[name] else { return false }
        return depth <= maxDepth
    }

    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? { self.bundle(at: bundle, counted: false)?.info }
}
