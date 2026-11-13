// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Checks on the app bundle the App scheme just built (it builds the app before running this bundle): Sparkle keys
// in Info.plist (PLT-R1101, PLT-R1102, PRD-R55), Sparkle as the only embedded framework at the pinned version
// (PLT-R104) and the compiled Updates table in both languages (PRD-R62). The app is read, never launched.

#if UPDATER_TESTS
import AppModel
import Foundation
import ShellCore
import Testing

@Suite struct BuiltBundleTests {
    /// The app in the products directory next to this test bundle: the one whose Info.plist has `SUFeedURL`.
    static func builtApp() throws -> Bundle {
        let products = Bundle(for: FakeUpdateDriver.self).bundleURL.deletingLastPathComponent()
        let apps = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        let app = apps.compactMap(Bundle.init(url:)).first {
            $0.object(forInfoDictionaryKey: UpdaterConfiguration.InfoKey.feedURL) != nil
        }
        return try #require(app, "build the App scheme first (xcodebuild -scheme App test builds it)")
    }

    static func info() throws -> [String: Any] { try builtApp().infoDictionary ?? [:] }

    @Test("PLT-R1101: SUFeedURL is https://<AppSiteHost>/appcast.xml, both expanded from Config/Brand.xcconfig")
    func feedURLFromSiteHost() throws {
        let info = try Self.info()
        let siteHost = try #require(info[Brand.InfoKey.siteHost] as? String)
        #expect(!siteHost.isEmpty && !siteHost.contains("$("))
        let feed = try #require(info[UpdaterConfiguration.InfoKey.feedURL] as? String)
        #expect(URL(string: feed) == UpdaterConfiguration.expectedFeedURL(siteHost: siteHost))
    }

    @Test("PRD-R55, PLT-R1102, PLT-R1105: profiling off, daily checks, automatic download, verify before extraction")
    func sparkleKeys() throws {
        let info = try Self.info()
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }

    @Test("PLT-R1102: SUPublicEDKey is present; until Pa fills it, it is empty and the updater refuses to start")
    func publicKeyPlaceholderOrValid() throws {
        let info = try Self.info()
        let key = try #require(info[UpdaterConfiguration.InfoKey.publicEDKey] as? String)
        #expect(!key.hasPrefix("$("))
        if key.isEmpty {
            #expect(UpdaterConfiguration.refusal(info: info) == .publicKey)
        } else {
            #expect(UpdaterConfiguration.isEd25519PublicKey(key))
            #expect(UpdaterConfiguration.refusal(info: info) == nil)
        }
    }

    @Test("PLT-R104: Sparkle is the only embedded framework, at the pinned 2.10.1")
    func sparkleOnly() throws {
        let frameworks = try #require(try Self.builtApp().privateFrameworksURL)
        // Sanitizer builds (`-enableThreadSanitizer YES`) also embed their runtime, which never ships.
        let embedded = try FileManager.default.contentsOfDirectory(atPath: frameworks.path)
            .filter { !$0.hasPrefix("libclang_rt.") }.sorted()
        #expect(embedded == ["Sparkle.framework"])
        let sparkle = try #require(Bundle(url: frameworks.appendingPathComponent("Sparkle.framework")))
        #expect(sparkle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "2.10.1")
    }

    @Test("PRD-R62: the Updates table is compiled into vi.lproj and en.lproj and resolves per language")
    func compiledCatalog() throws {
        let app = try Self.builtApp()
        for language in InterfaceLanguage.allCases {
            let localizer = Localizer(language: language, appBundle: app)
            for key in UpdatesText.allCases {
                #expect(localizer.contains(key.rawValue, table: .updates), "\(language.rawValue): \(key.rawValue)")
            }
        }
        #expect(Localizer(language: .vietnamese, appBundle: app).string(UpdatesText.retry) == "Thử lại")
        #expect(Localizer(language: .english, appBundle: app).string(UpdatesText.retry) == "Try Again")
    }
}
#endif
