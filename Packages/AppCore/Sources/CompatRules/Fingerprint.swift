// SPDX-License-Identifier: GPL-3.0-or-later
//
// Engine fingerprinting (PLT-R510). Pure logic over a `BundleInspector`; the ax thread caches results per
// (bundle path, CFBundleVersion). Every heuristic is VERIFY against current builds.

public import AppModel
public import Foundation

/// Read-only view of an app bundle. Production implementation in InputHost (FileManager); fake in TestSupport.
public protocol BundleInspector: Sendable {
    /// Names inside `Contents/Frameworks` (for example `Electron Framework.framework`).
    func frameworkNames(in bundle: URL) -> [String]
    /// Names of nested helper apps (for example `Google Chrome Helper (Renderer).app`).
    func helperAppNames(in bundle: URL) -> [String]
    /// True if a file with this name is at most `maxDepth` levels below `directory` (1 = directly inside), for
    /// example `libjvm.dylib` under `<bundle>/Contents/jbr`. `directory` is a folder inside the bundle chosen by
    /// the caller; a missing folder yields false. The fingerprinter only passes known library folders and
    /// depths up to 6, so implementations walk a bounded subtree on the ax thread (PLT-R510, PLT-R384).
    func containsFile(named name: String, in directory: URL, maxDepth: Int) -> Bool
    func infoDictionary(of bundle: URL) -> [String: JSONValue]?
}

public struct EngineFingerprinter: Sendable {
    public init(inspector: any BundleInspector, webkitBrowsers: Set<BundleKey>) {
        self.inspector = inspector
        self.webkitBrowsers = webkitBrowsers
    }

    let inspector: any BundleInspector
    let webkitBrowsers: Set<BundleKey>

    /// Order: webkitBrowser (rules group) > electron > cef > chromium > gecko > jvm > qt > ios > catalyst >
    /// native.
    public func fingerprint(bundleURL: URL, bundle: BundleKey?) -> EngineFingerprint {
        if let bundle, webkitBrowsers.contains(bundle) { return .webkitBrowser }
        return EngineHeuristics(inspector: inspector, bundleURL: bundleURL).classify()
    }
}
