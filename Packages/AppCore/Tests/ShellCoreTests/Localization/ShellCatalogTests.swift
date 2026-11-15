// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shell-specific copy checks (PRD-R10, PRD-R66, ADR 0310). The generic checks of every table (vi and en,
// format arguments, brand, dashes, referenced and orphaned keys, literal copy) live in CatalogAuditTests; the
// control scans of every window in AccessibilitySourceAuditTests.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct ShellCatalogTests {
    @Test func everyOnboardingControlHasLabelAndHint() throws {
        // PRD-R66
        let catalog = try Catalog(table: .onboarding)
        for control in OnboardingControl.allCases {
            #expect(catalog.entries[control.accessibilityLabelKey] != nil, "\(control) label")
            #expect(catalog.entries[control.accessibilityHintKey] != nil, "\(control) hint")
        }
    }

    @Test func iconLabelsAreVerbatimFromPRDR10() throws {
        let app = try TemporaryAppBundle(catalogs: [.menu])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        let expected: [StatusIconState: (String, String)] = [
            .vietnamese: ("Đang gõ tiếng Việt", "Vietnamese typing on"),
            .english: ("Đang gõ tiếng Anh", "English typing"),
            .ignoredApp: ("Bỏ qua ứng dụng này", "Ignored in this app"),
            .secureInputVietnamese: ("Ô bảo mật đang bật", "Secure input active"),
            .secureInputEnglish: ("Ô bảo mật đang bật", "Secure input active"),
            .paused: ("Tạm dừng: đang dùng bộ gõ khác", "Paused: another input source is active"),
            .permissionMissing: ("Cảnh báo: chưa gõ được, cần cấp quyền", "Warning: not working, permission needed"),
            .notWorking: (
                "Chưa gõ được: mở menu để xem cách khắc phục", "Not working: open the menu to see how to fix it"
            ),
        ]
        for (state, (viLabel, enLabel)) in expected {
            #expect(vi.string(state.accessibilityLabelKey, table: .menu) == viLabel)
            #expect(en.string(state.accessibilityLabelKey, table: .menu) == enLabel)
        }
    }

    @Test func compositionCopyResolvesThroughTheSharedLocalizer() throws {
        // The composition root's alerts read the `Composition` table through `Localizer` (ADR 0310), so a
        // language change and the Vietnamese fallback behave as for every other table.
        let app = try TemporaryAppBundle(catalogs: [.composition])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(StringTable.composition.rawValue == "Composition")
        #expect(vi.format(CompositionText.safeModeTitle, "App") == "App đang chạy ở chế độ an toàn")
        #expect(en.format(CompositionText.safeModeTitle, "App") == "App is running in safe mode")
        #expect(en.string(CompositionText.conflictsDismiss) == "OK")
    }
}

/// Brand values from the brand files, so tests never hard-code the temporary name either.
enum BrandFiles {
    struct Values {
        var displayName: String
        var siteHost: String
        var bundleID: String
    }

    static func values() throws -> Values {
        let text = try String(contentsOf: RepoPaths.url("scripts/brand.env"), encoding: .utf8)
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            map[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Values(
            displayName: try #require(map["APP_DISPLAY_NAME"]), siteHost: try #require(map["APP_SITE_HOST"]),
            bundleID: try #require(map["APP_BUNDLE_ID_RELEASE"]))
    }
}
