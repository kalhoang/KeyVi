// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The single runtime source of the product name (CLAUDE.md "Name (temporary)"). Values come from Info.plist
// keys that project.yml fills from Config/Brand.xcconfig; nothing here is hard-coded.

internal import AppModel
public import Foundation

public struct Brand: Sendable, Hashable {
    /// Info.plist keys (project.yml): `CFBundleDisplayName` = $(APP_DISPLAY_NAME),
    /// `AppSlug` = $(APP_SLUG), `AppSiteHost` = $(APP_SITE_HOST).
    public enum InfoKey {
        public static let displayName = "CFBundleDisplayName"
        public static let slug = "AppSlug"
        public static let siteHost = "AppSiteHost"
        public static let supportEmail = "AppSupportEmail"  // VERIFY with Pa (QA-R51)
    }

    public var displayName: String
    public var slug: String
    public var siteHost: String
    public var bundleIdentifier: String
    public var version: String  // CFBundleShortVersionString
    public var build: String  // CFBundleVersion
    public var supportEmail: String?

    public init(
        displayName: String, slug: String, siteHost: String, bundleIdentifier: String, version: String, build: String,
        supportEmail: String?
    ) {
        self.displayName = displayName
        self.slug = slug
        self.siteHost = siteHost
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.supportEmail = supportEmail
    }

    /// Reads the bundle; traps with a clear message if a key is missing (a build-configuration error).
    public static func from(_ bundle: Bundle) -> Brand { unimplemented() }

    /// Folder name under Application Support and Logs: the display name if it is pure ASCII, else the slug
    /// (PLT-R903). Frozen at the first public release (docs/decisions/0307-settings-file-layout.md).
    public var storageFolderName: String { displayName.allSatisfy(\.isASCII) ? displayName : slug }

    public var siteURL: URL { URL(string: "https://\(siteHost)/")! }
    /// URL scheme that may only open Settings (PLT-R909).
    public var urlScheme: String { slug }
}

