// SPDX-License-Identifier: GPL-3.0-or-later
//
// The single runtime source of the product name (CLAUDE.md "Name (temporary)"). Values come from Info.plist
// keys that project.yml fills from Config/Brand.xcconfig; nothing here is hard-coded. Implemented in the
// skeleton because the App reads it at launch (ADR 0313); workstream W1-G owns it.

internal import AppModel
public import Foundation

public struct Brand: Sendable, Hashable {
    /// Info.plist keys (App/Info.plist): `CFBundleDisplayName` = $(APP_DISPLAY_NAME), `AppSlug` = $(APP_SLUG),
    /// `AppSiteHost` = $(APP_SITE_HOST), `AppSupportEmail` = $(APP_SUPPORT_EMAIL),
    /// `AppRepositoryURL` = $(APP_REPOSITORY_URL), `AppLegacyStorageFolderNames` =
    /// $(APP_LEGACY_STORAGE_FOLDER_NAMES) (semicolon-separated, ADR 0307).
    public enum InfoKey {
        public static let displayName = "CFBundleDisplayName"
        public static let slug = "AppSlug"
        public static let siteHost = "AppSiteHost"
        public static let supportEmail = "AppSupportEmail"  // VERIFY with Pa (QA-R51)
        public static let repositoryURL = "AppRepositoryURL"  // VERIFY with Pa (PRD-R47, QA-R60)
        public static let legacyStorageFolderNames = "AppLegacyStorageFolderNames"
        public static let bundleIdentifier = "CFBundleIdentifier"
        public static let version = "CFBundleShortVersionString"
        public static let build = "CFBundleVersion"
    }

    public var displayName: String
    public var slug: String
    public var siteHost: String
    public var bundleIdentifier: String
    public var version: String  // CFBundleShortVersionString
    public var build: String  // CFBundleVersion
    public var supportEmail: String?
    /// GitHub repository for issue forms; nil until Pa decides (the GitHub path is hidden then).
    public var repositoryURL: URL?
    /// Storage folder names used by earlier product names, newest first, for the one-time move after a rename
    /// (ADR 0307, `LegacyStorageMigrator`).
    public var legacyStorageFolderNames: [String]

    public init(
        displayName: String, slug: String, siteHost: String, bundleIdentifier: String, version: String, build: String,
        supportEmail: String?, repositoryURL: URL? = nil, legacyStorageFolderNames: [String] = []
    ) {
        self.displayName = displayName
        self.slug = slug
        self.siteHost = siteHost
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.supportEmail = supportEmail
        self.repositoryURL = repositoryURL
        self.legacyStorageFolderNames = legacyStorageFolderNames
    }

    /// Reads the bundle; traps with a clear message if a required key is missing or empty (a build
    /// configuration error, never a user-facing state).
    public static func from(_ bundle: Bundle) -> Brand {
        from(info: bundle.infoDictionary ?? [:])
    }

    /// Same as `from(_:)` over a plain dictionary (tests).
    public static func from(info: [String: Any]) -> Brand {
        func required(_ key: String) -> String {
            guard let value = info[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else {
                preconditionFailure("Info.plist key \(key) is missing; check Config/Brand.xcconfig and App/Info.plist")
            }
            return value
        }
        func optional(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
            return value
        }
        let repository = optional(InfoKey.repositoryURL).flatMap { value -> URL? in
            guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
            return url
        }
        let legacy = (optional(InfoKey.legacyStorageFolderNames) ?? "")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Brand(
            displayName: required(InfoKey.displayName), slug: required(InfoKey.slug),
            siteHost: required(InfoKey.siteHost), bundleIdentifier: required(InfoKey.bundleIdentifier),
            version: optional(InfoKey.version) ?? "0", build: optional(InfoKey.build) ?? "0",
            supportEmail: optional(InfoKey.supportEmail), repositoryURL: repository,
            legacyStorageFolderNames: legacy)
    }

    /// Folder name under Application Support and Logs: the display name if it is pure ASCII, else the slug
    /// (PLT-R903). Frozen at the first public release (docs/decisions/0307-settings-file-layout.md).
    public var storageFolderName: String { Self.folderName(displayName: displayName, slug: slug) }

    /// PLT-R903 rule, shared with the legacy-folder migration.
    public static func folderName(displayName: String, slug: String) -> String {
        displayName.allSatisfy(\.isASCII) ? displayName : slug
    }

    public var siteURL: URL { URL(string: "https://\(siteHost)/")! }
    /// URL scheme that may only open Settings (PLT-R909).
    public var urlScheme: String { slug }
}
