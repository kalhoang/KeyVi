// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Skeleton seam tests (ADR 0313): keep green; W1-G owns and may extend.
import Foundation
import Testing
@testable import ShellCore

@Suite struct BrandTests {
    private let info: [String: Any] = [
        "CFBundleDisplayName": "Example Name", "AppSlug": "example", "AppSiteHost": "example.invalid",
        "CFBundleIdentifier": "invalid.example.app", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7",
        "AppSupportEmail": "", "AppRepositoryURL": "https:/$()/not-substituted",
        "AppLegacyStorageFolderNames": "Old Name; Older Name ;",
    ]

    @Test func readsInfoDictionary() {
        let brand = Brand.from(info: info)
        #expect(brand.displayName == "Example Name")
        #expect(brand.slug == "example")
        #expect(brand.version == "0.1.0")
        #expect(brand.build == "7")
        #expect(brand.supportEmail == nil)  // empty means "not decided"
        #expect(brand.repositoryURL == nil)  // only https URLs with a host count
        #expect(brand.legacyStorageFolderNames == ["Old Name", "Older Name"])
        #expect(brand.storageFolderName == "Example Name")
        #expect(brand.siteURL.absoluteString == "https://example.invalid/")
    }

    @Test func repositoryURLAndNonASCIIFolder() {
        var custom = info
        custom["AppRepositoryURL"] = "https://github.com/example/repo"
        custom["CFBundleDisplayName"] = "Xuôi"
        let brand = Brand.from(info: custom)
        #expect(brand.repositoryURL?.host == "github.com")
        #expect(brand.storageFolderName == "example")
    }
}
