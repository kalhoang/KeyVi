// SPDX-License-Identifier: LicenseRef-App-Pending
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
    /// True if a file with this name exists anywhere under `Contents` (bounded depth, for example
    /// `libxul.dylib`, `libjvm.dylib`).
    func containsFile(named name: String, in bundle: URL, maxDepth: Int) -> Bool
    func infoDictionary(of bundle: URL) -> [String: JSONValue]?
}

public struct EngineFingerprinter: Sendable {
    public init(inspector: any BundleInspector, webkitBrowsers: Set<BundleKey>) { unimplemented() }

    /// Order: webkitBrowser (rules group) > electron > cef > chromium > gecko > jvm > qt > ios > catalyst >
    /// native.
    public func fingerprint(bundleURL: URL, bundle: BundleKey?) -> EngineFingerprint { unimplemented() }
}
