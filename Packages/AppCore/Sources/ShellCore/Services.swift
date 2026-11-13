// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
public import Foundation
internal import ServiceManagement

/// Launch at login (PLT-R205, D17). Production: `SMAppService.mainApp` `status`, `register()`, `unregister()`;
/// `requiresApproval` opens System Settings > Login Items via `SMAppService.openSystemSettingsLoginItems()`.
/// macOS 12 has no `SMAppService` (ADR 0315): the status is `unavailable`, the user adds the app by hand and
/// `openSystemSettings()` opens System Preferences > Users & Groups.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

public enum LoginItemStatus: String, Sendable, Hashable {
    case enabled, notRegistered, requiresApproval, notFound
    /// macOS 12: the app cannot register itself; the user adds it in System Preferences (ADR 0315).
    case unavailable
}

/// `register()` and `unregister()` on macOS 12, where the app cannot change its own login item.
public struct LoginItemUnavailable: Error, Sendable, Hashable {
    public init() {}
}

/// Thin wrapper; `status(from:)` and the macOS 12 branch are unit tested because the other members change the
/// user's login items (verified by Pa, traceability PLT-R205).
public struct SMAppServiceLoginItem: LoginItemService {
    private let usesService: Bool
    private let openLegacyLoginItems: @Sendable () -> Void

    /// - Parameter openLegacyLoginItems: macOS 12 only. Opens System Preferences > Users & Groups (the
    ///   `loginItems` deep link of SystemPanes.json) so the user can add the app to Login Items.
    public init(openLegacyLoginItems: @escaping @Sendable () -> Void = {}) {
        self.init(usesService: Self.serviceExists, openLegacyLoginItems: openLegacyLoginItems)
    }

    /// `usesService: false` is the macOS 12 behaviour (tests run it on any system).
    init(usesService: Bool, openLegacyLoginItems: @escaping @Sendable () -> Void) {
        self.usesService = usesService
        self.openLegacyLoginItems = openLegacyLoginItems
    }

    static var serviceExists: Bool {
        if #available(macOS 13, *) { true } else { false }
    }

    public var status: LoginItemStatus {
        if usesService, #available(macOS 13, *) { return Self.status(from: SMAppService.mainApp.status) }
        return .unavailable
    }

    public func register() throws {
        guard usesService, #available(macOS 13, *) else { throw LoginItemUnavailable() }
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        guard usesService, #available(macOS 13, *) else { throw LoginItemUnavailable() }
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        guard usesService, #available(macOS 13, *) else { return openLegacyLoginItems() }
        SMAppService.openSystemSettingsLoginItems()
    }

    @available(macOS 13, *)
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
