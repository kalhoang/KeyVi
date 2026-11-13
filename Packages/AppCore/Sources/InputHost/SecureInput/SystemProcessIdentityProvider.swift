// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production `ProcessIdentityProvider` (PLT-R393, PLT-R396, PLT-R399, PLT-R510). Thin: the system reads are
// here, the mapping to `ProcessIdentity` is `ProcessIdentityFactory` (pure, unit-tested).

import AppKit
import AppModel
import Darwin
import Foundation

public struct SystemProcessIdentityProvider: ProcessIdentityProvider {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0, isAlive(pid) else { return nil }
        let application = NSRunningApplication(processIdentifier: pid)
        let bundleURL = application?.bundleURL
        let info = bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        return ProcessIdentityFactory.make(
            pid: pid, bundleIdentifier: application?.bundleIdentifier, bundleURL: bundleURL,
            info: ProcessIdentityFactory.BundleInfo(info), executablePath: Self.executablePath(of: pid),
            processName: Self.processName(of: pid), localizedName: application?.localizedName)
    }

    /// `kill(pid, 0)`: EPERM still means the process exists (owned by another user).
    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func runningApplications() -> [ProcessIdentity] {
        NSWorkspace.shared.runningApplications.compactMap { identity(of: $0.processIdentifier) }
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func processName(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

enum ProcessIdentityFactory {
    /// The Info.plist keys host services read.
    struct BundleInfo: Sendable, Hashable {
        var shortVersion: String?
        var buildVersion: String?
        var appCategory: String?

        init(shortVersion: String? = nil, buildVersion: String? = nil, appCategory: String? = nil) {
            self.shortVersion = shortVersion
            self.buildVersion = buildVersion
            self.appCategory = appCategory
        }

        init(_ dictionary: [String: Any]?) {
            shortVersion = dictionary?["CFBundleShortVersionString"] as? String
            buildVersion = dictionary?["CFBundleVersion"] as? String
            appCategory = dictionary?["LSApplicationCategoryType"] as? String
        }
    }

    /// PLT-R393: a process without a (valid) bundle identifier is keyed by the SHA-256 of its executable path.
    /// Returns nil only when neither a bundle identifier nor an executable path is known.
    static func make(
        pid: Int32, bundleIdentifier: String?, bundleURL: URL?, info: BundleInfo, executablePath: String?,
        processName: String, localizedName: String?
    ) -> ProcessIdentity? {
        let key =
            bundleIdentifier.flatMap(BundleKey.init(rawValue:)).flatMap { $0.isExecutableHash ? nil : $0 }
            ?? executablePath.flatMap { BundleKey.executable(sha256Hex: HostServicesHashing.sha256Hex($0)) }
        guard let key else { return nil }
        let fallbackName = executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let name = processName.isEmpty ? fallbackName : processName
        return ProcessIdentity(
            pid: pid, bundle: key, bundleURL: bundleURL, shortVersion: info.shortVersion,
            buildVersion: info.buildVersion, appCategory: info.appCategory, localizedName: localizedName,
            processName: name)
    }
}
