// SPDX-License-Identifier: LicenseRef-App-Pending
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
        static let geckoDepth = 3  // Contents/MacOS/libxul.dylib
        static let javaLibrary = "libjvm.dylib"
        static let javaDepth = 7  // Contents/jbr/Contents/Home/lib/server/libjvm.dylib
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
        if inspector.containsFile(named: Marker.geckoLibrary, in: bundleURL, maxDepth: Marker.geckoDepth) {
            return .gecko
        }
        if inspector.containsFile(named: Marker.javaLibrary, in: bundleURL, maxDepth: Marker.javaDepth) {
            return .jvm
        }
        if frameworks.contains(Marker.qtFramework) { return .qt }
        let info = inspector.infoDictionary(of: bundleURL) ?? [:]
        if Self.isIOS(info) { return .ios }
        if Self.isCatalyst(info) { return .catalyst }
        return .native
    }

    /// A `* Framework.framework` together with a `* Helper (Renderer).app` helper.
    private func isChromium(_ frameworks: [String]) -> Bool {
        guard frameworks.contains(where: { $0.hasSuffix(Marker.chromiumFrameworkSuffix) }) else { return false }
        return inspector.helperAppNames(in: bundleURL).contains { $0.hasSuffix(Marker.chromiumRendererSuffix) }
    }

    /// An iOS app running on Apple silicon declares the iPhoneOS platform (VERIFY).
    static func isIOS(_ info: [String: JSONValue]) -> Bool {
        if info[Marker.requiresIPhoneOSKey] == .bool(true) { return true }
        guard case .array(let platforms) = info[Marker.supportedPlatformsKey] else { return false }
        return platforms.contains(.string(Marker.iOSPlatform))
    }

    /// A Mac Catalyst app keeps UIKit's device family key in a macOS bundle (VERIFY).
    static func isCatalyst(_ info: [String: JSONValue]) -> Bool {
        info[Marker.deviceFamilyKey] != nil
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
