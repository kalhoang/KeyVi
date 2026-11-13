// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
public import Foundation

/// Launch at login (PLT-R205, D17). Production: `SMAppService.mainApp` `status`, `register()`,
/// `unregister()`; `requiresApproval` opens System Settings > Login Items via `SMAppService.openSystemSettingsLoginItems()`.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

public enum LoginItemStatus: String, Sendable, Hashable { case enabled, notRegistered, requiresApproval, notFound }

public struct SMAppServiceLoginItem: LoginItemService {
    public init() {}
    public var status: LoginItemStatus { unimplemented() }
    public func register() throws { unimplemented() }
    public func unregister() throws { unimplemented() }
    public func openSystemSettings() { unimplemented() }
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
    public static func route(_ url: URL, scheme: String) -> Route { unimplemented() }
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

