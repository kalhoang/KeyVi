// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bundle heuristics of PLT-R510, in the documented order. Every marker is VERIFY against current builds; they
// are names Apple's bundle layout makes visible (frameworks, helper apps, Info.plist keys), never app identity.

public import AppModel
public import Foundation

struct EngineHeuristics {
    let inspector: any BundleInspector
    let bundleURL: URL

    enum Marker {
        static let electronFramework = "Electron Framework.framework"
        static let cefFramework = "Chromium Embedded Framework.framework"
        static let chromiumFrameworkSuffix = " Framework.framework"
        static let chromiumRendererSuffix = " Helper (Renderer).app"
        static let geckoLibrary = "libxul.dylib"
        /// Contents/MacOS/libxul.dylib (depth 1); Frameworks for embedders.
        static let geckoRoots = ["Contents/MacOS", "Contents/Frameworks"]
        static let geckoDepth = 2
        static let javaLibrary = "libjvm.dylib"
        /// Where a bundled Java runtime lives: jbr/Contents/Home/lib/server/libjvm.dylib (depth 5), jpackage
        /// `runtime`, a JDK in PlugIns or Frameworks, a JRE in Resources (`jre/Contents/Home/...`, depth 6).
        static let javaRoots = [
            "Contents/jbr", "Contents/runtime", "Contents/PlugIns", "Contents/Frameworks", "Contents/Resources",
        ]
        static let javaDepth = 6
        static let qtFramework = "QtCore.framework"
        static let supportedPlatformsKey = "CFBundleSupportedPlatforms"
        static let iOSPlatform = "iPhoneOS"
        static let requiresIPhoneOSKey = "LSRequiresIPhoneOS"
        static let deviceFamilyKey = "UIDeviceFamily"
    }

    /// electron > cef > chromium > gecko > jvm > qt > ios > catalyst > native (webkitBrowser is decided by the
    /// rules group before this runs).
    func classify() -> EngineFingerprint {
        let frameworks = inspector.frameworkNames(in: bundleURL)
        if frameworks.contains(Marker.electronFramework) { return .electron }
        if frameworks.contains(Marker.cefFramework) { return .cef }
        if isChromium(frameworks) { return .chromium }
        if containsFile(Marker.geckoLibrary, under: Marker.geckoRoots, maxDepth: Marker.geckoDepth) {
            return .gecko
        }
        if containsFile(Marker.javaLibrary, under: Marker.javaRoots, maxDepth: Marker.javaDepth) {
            return .jvm
        }
        if frameworks.contains(Marker.qtFramework) { return .qt }
        let info = inspector.infoDictionary(of: bundleURL) ?? [:]
        if Self.isIOS(info) { return .ios }
        if Self.isCatalyst(info) { return .catalyst }
        return .native
    }

    /// PLT-R510 on the ax thread (PLT-R384): search only the folders where the library lives, never the whole
    /// bundle, so the first fingerprint of a large app (an IDE, a game) stays cheap.
    private func containsFile(_ name: String, under roots: [String], maxDepth: Int) -> Bool {
        roots.contains { root in
            inspector.containsFile(
                named: name, in: bundleURL.appendingPathComponent(root, isDirectory: true), maxDepth: maxDepth)
        }
    }

    /// A `* Framework.framework` together with a `* Helper (Renderer).app` helper.
    private func isChromium(_ frameworks: [String]) -> Bool {
        guard frameworks.contains(where: { $0.hasSuffix(Marker.chromiumFrameworkSuffix) }) else { return false }
        return inspector.helperAppNames(in: bundleURL).contains { $0.hasSuffix(Marker.chromiumRendererSuffix) }
    }

    /// An iOS app running on Apple silicon declares the iPhoneOS platform (VERIFY). The platform list decides
    /// when present: a Catalyst build of an iOS target often keeps `LSRequiresIPhoneOS` but lists only MacOSX.
    static func isIOS(_ info: [String: JSONValue]) -> Bool {
        if case .array(let platforms) = info[Marker.supportedPlatformsKey] {
            return platforms.contains(.string(Marker.iOSPlatform))
        }
        return info[Marker.requiresIPhoneOSKey] == .bool(true)
    }

    /// A Mac Catalyst app keeps UIKit keys (device family, `LSRequiresIPhoneOS`) in a macOS bundle (VERIFY).
    /// Checked after `isIOS`, so these keys only mean Catalyst when the platform list is not iPhoneOS.
    static func isCatalyst(_ info: [String: JSONValue]) -> Bool {
        info[Marker.deviceFamilyKey] != nil || info[Marker.requiresIPhoneOSKey] == .bool(true)
    }
}

/// Memo of fingerprints for the ax thread (PLT-R510): one inspection per (bundle path, `CFBundleVersion`), so
/// an app update is fingerprinted again. A value type: the owner keeps it confined to one thread.
public struct EngineFingerprintCache: Sendable {
    private let fingerprinter: EngineFingerprinter
    private let capacity: Int
    private var entries: [String: EngineFingerprint] = [:]

    public init(fingerprinter: EngineFingerprinter, capacity: Int = 256) {
        self.fingerprinter = fingerprinter
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    public mutating func fingerprint(bundleURL: URL, bundle: BundleKey?) -> EngineFingerprint {
        let version = fingerprinter.inspector.infoDictionary(of: bundleURL)?["CFBundleVersion"]?.stringValue ?? ""
        let key = bundleURL.standardizedFileURL.path + "\u{0}" + version + "\u{0}" + (bundle?.rawValue ?? "")
        if let known = entries[key] { return known }
        let result = fingerprinter.fingerprint(bundleURL: bundleURL, bundle: bundle)
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = result
        return result
    }
}
