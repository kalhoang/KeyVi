// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R909 URL scheme, PLT-R205 login item status mapping (the real register/unregister are Pa's manual check).

import AppModel
import Foundation
import RealtimeSupport
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

    /// ADR 0315, PLT-R205: macOS 12 has no `SMAppService`. The service says so instead of failing silently, and
    /// "Mở Tùy chọn hệ thống" opens the Users & Groups pane where the user adds the app by hand.
    @Test func withoutServiceManagementTheItemIsUnavailable() {
        let opened = Atomic<Int>(0)
        let item = SMAppServiceLoginItem(usesService: false) { opened.wrappingAdd(1, ordering: .relaxed) }
        #expect(item.status == .unavailable)
        #expect(throws: LoginItemUnavailable.self) { try item.register() }
        #expect(throws: LoginItemUnavailable.self) { try item.unregister() }
        item.openSystemSettings()
        #expect(opened.load(ordering: .relaxed) == 1)
    }

    @Test func serviceManagementExistsOnTheTestSystem() {
        // The tests run on macOS 13 or later, where the production initialiser uses SMAppService.
        #expect(SMAppServiceLoginItem.serviceExists)
    }

    @Test func donationPlaceholderIsMarkedForVerification() {
        // PRD-R59: details are placeholders until Pa verifies them; QR images are bundled assets.
        #expect(DonationInfo.placeholder.bankAccountName == "VERIFY")
        #expect(DonationInfo.placeholder.githubSponsorsURL == nil)
    }
}
