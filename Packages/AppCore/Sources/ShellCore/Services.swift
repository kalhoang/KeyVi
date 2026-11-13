// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
public import Foundation
internal import ServiceManagement

/// Launch at login (PLT-R205, D17). Production: `SMAppService.mainApp` `status`, `register()`,
/// `unregister()`; `requiresApproval` opens System Settings > Login Items via `SMAppService.openSystemSettingsLoginItems()`.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

public enum LoginItemStatus: String, Sendable, Hashable { case enabled, notRegistered, requiresApproval, notFound }

/// Thin wrapper; only `status(from:)` is unit tested because the other members change the user's login items
/// (verified by Pa, traceability PLT-R205).
public struct SMAppServiceLoginItem: LoginItemService {
    public init() {}
    public var status: LoginItemStatus { Self.status(from: SMAppService.mainApp.status) }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    static func status(from status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

/// What the About & Support pane needs from the Sparkle wrapper (App/Updater), so its view model is testable.
@MainActor
public protocol UpdaterControlling: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var channel: UpdateChannelSelection { get set }
    func checkForUpdates()
}

public enum UpdateChannelSelection: String, Sendable, Hashable { case stable, beta }

/// PLT-R909: `<slug>://` may only open Settings; every other component or parameter is ignored.
public enum URLSchemeRouter {
    public enum Route: Sendable, Hashable { case openSettings, ignore }

    /// Any URL with the app's scheme opens Settings and nothing else: host, path, query and fragment never select
    /// a pane, change a setting, start a capture or export data.
    public static func route(_ url: URL, scheme: String) -> Route {
        guard let urlScheme = url.scheme, !scheme.isEmpty else { return .ignore }
        return urlScheme.caseInsensitiveCompare(scheme) == .orderedSame ? .openSettings : .ignore
    }
}

/// Donation block (PRD-R59). Account details are placeholders until Pa verifies them; QR images are bundled
/// assets, never fetched.
public struct DonationInfo: Sendable, Hashable {
    public var bankAccountName: String  // VERIFY
    public var vietQRImageName: String  // asset catalog name
    public var momoQRImageName: String
    public var githubSponsorsURL: URL?  // VERIFY
    public static let placeholder = DonationInfo(
        bankAccountName: "VERIFY", vietQRImageName: "DonationVietQR", momoQRImageName: "DonationMoMo",
        githubSponsorsURL: nil)
}
