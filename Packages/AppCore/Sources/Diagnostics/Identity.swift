// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel

/// Build metadata read from the bundle by the App's `Brand` helper and injected into AppCore. Bundle metadata
/// is not user content, so it is an allowed metadata type for logs and reports (PLT-R901, PLT-R902).
public struct AppIdentity: Sendable, Hashable, Codable {
    public var displayName: String
    public var slug: String
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var channel: UpdateChannel

    public init(
        displayName: String, slug: String, bundleIdentifier: String, version: String, build: String,
        channel: UpdateChannel
    ) {
        self.displayName = displayName
        self.slug = slug
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.channel = channel
    }
}

/// Host metadata for reports (PLT-R1202).
public struct SystemInfo: Sendable, Hashable, Codable {
    public var macOSVersion: String  // "27.1"
    public var macOSBuild: String  // "26B123"
    public var architecture: String  // "arm64" or "x86_64"
    public var modelIdentifier: String  // sysctl hw.model
    public var uiLanguage: InterfaceLanguage
    public var systemLanguage: String  // BCP 47 tag of the macOS primary language

    public init(
        macOSVersion: String, macOSBuild: String, architecture: String, modelIdentifier: String,
        uiLanguage: InterfaceLanguage, systemLanguage: String
    ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.architecture = architecture
        self.modelIdentifier = modelIdentifier
        self.uiLanguage = uiLanguage
        self.systemLanguage = systemLanguage
    }
}
