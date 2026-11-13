// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R909 URL scheme, PLT-R205 login item status mapping (the real register/unregister are Pa's manual check).

import AppModel
import Foundation
import ServiceManagement
import Testing

@testable import ShellCore

@Suite struct URLSchemeRouterTests {
    @Test func ourSchemeOnlyEverOpensSettings() throws {
        let urls = [
            "example://", "example://settings", "EXAMPLE://capture/start?duration=180",
            "example://export?path=/tmp/x", "example:set?typingMethod=vni", "example://reset#all",
        ]
        for text in urls {
            let url = try #require(URL(string: text))
            #expect(URLSchemeRouter.route(url, scheme: "example") == .openSettings, "\(text)")
        }
    }

    @Test func otherSchemesAreIgnored() throws {
        for text in ["https://example.invalid/", "file:///tmp/x", "examples://", "other://example", "/relative"] {
            let url = try #require(URL(string: text))
            #expect(URLSchemeRouter.route(url, scheme: "example") == .ignore, "\(text)")
        }
        #expect(URLSchemeRouter.route(URL(string: "example://")!, scheme: "") == .ignore)
    }
}

@Suite struct LoginItemTests {
    @Test func everyServiceManagementStatusMaps() {
        #expect(SMAppServiceLoginItem.status(from: .enabled) == .enabled)
        #expect(SMAppServiceLoginItem.status(from: .notRegistered) == .notRegistered)
        #expect(SMAppServiceLoginItem.status(from: .requiresApproval) == .requiresApproval)
        #expect(SMAppServiceLoginItem.status(from: .notFound) == .notFound)
    }

    @Test func donationDetailsArePasBankAccount_PRDR59() {
        // Pa's decision S8: LioBank, account 688688678, VietQR only; no sponsor page yet.
        #expect(DonationInfo.standard.bankName == "LioBank")
        #expect(DonationInfo.standard.accountNumber == "688688678")
        #expect(DonationInfo.standard.vietQRImageName == "DonationVietQR")
        #expect(DonationInfo.standard.githubSponsorsURL == nil)
    }
}
