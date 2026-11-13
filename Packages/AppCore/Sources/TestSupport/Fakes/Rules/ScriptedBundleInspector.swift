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
    /// What a bundle looks like from the outside: framework and helper names, files as paths relative to the
    /// bundle (for example `Contents/MacOS/libxul.dylib`), and the Info.plist.
    public struct FakeBundle: Sendable, Hashable {
        public var frameworks: [String]
        public var helpers: [String]
        public var files: [String]
        public var info: [String: JSONValue]?

        public init(
            frameworks: [String] = [], helpers: [String] = [], files: [String] = [],
            info: [String: JSONValue]? = nil
        ) {
            self.frameworks = frameworks
            self.helpers = helpers
            self.files = files
            self.info = info
        }
    }

    /// One `containsFile` call: the searched folder relative to the bundle, the file name and the depth bound.
    public struct FileSearch: Sendable, Hashable {
        public var directory: String
        public var name: String
        public var maxDepth: Int
    }

    private let bundles: Mutex<[String: FakeBundle]>
    private let calls = Mutex<Int>(0)
    private let searches = Mutex<[FileSearch]>([])

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

    /// Every `containsFile` call so far, in order.
    public var fileSearches: [FileSearch] { searches.withLock { $0 } }

    public func containsFile(named name: String, in directory: URL, maxDepth: Int) -> Bool {
        calls.withLock { $0 += 1 }
        let target = directory.path
        guard
            let (root, bundle) = bundles.withLock({ all in
                all.first { target == $0.key || target.hasPrefix($0.key + "/") }
            })
        else { return false }
        let relative = target.dropFirst(root.count).split(separator: "/")
        searches.withLock {
            $0.append(FileSearch(directory: relative.joined(separator: "/"), name: name, maxDepth: maxDepth))
        }
        return bundle.files.contains { path in
            let components = path.split(separator: "/")
            guard components.last.map(String.init) == name, components.starts(with: relative) else { return false }
            return components.count - relative.count <= maxDepth
        }
    }

    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? { self.bundle(at: bundle, counted: false)?.info }
}
