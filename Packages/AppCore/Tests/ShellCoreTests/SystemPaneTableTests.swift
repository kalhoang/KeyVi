// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R701, PLT-R704, PRD-R64: pane names by macOS version and macOS language, deep links from data.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct SystemPaneTableTests {
    static func shipped() throws -> SystemPaneTable {
        try SystemPaneTable(resource: Data(contentsOf: RepoPaths.url("App/Resources/SystemPanes.json")))
    }

    func version(_ text: String) -> LooseVersion { LooseVersion(text)! }

    @Test func accessibilityIsRenamedOnMacOS27() throws {
        // PLT-R701, PRD-R40 dynamic instruction
        let table = try Self.shipped()
        #expect(table.names(macOS: version("15.4"), systemLanguage: "vi-VN").accessibility == "Trợ năng")
        #expect(table.names(macOS: version("26.1"), systemLanguage: "en-US").accessibility == "Accessibility")
        #expect(
            table.names(macOS: version("27.0"), systemLanguage: "vi-VN").accessibility
                == "Điều khiển thiết bị và truy cập dữ liệu")
        #expect(
            table.names(macOS: version("27.2"), systemLanguage: "en-GB").accessibility
                == "Device Control and Data Access")
    }

    @Test func namesFollowTheMacOSLanguageWithEnglishFallback() throws {
        // PRD-R64
        let table = try Self.shipped()
        let vi = table.names(macOS: version("26.0"), systemLanguage: "vi")
        #expect(vi.systemSettings == "Cài đặt hệ thống")
        #expect(vi.privacySecurity == "Quyền riêng tư & Bảo mật")
        let fr = table.names(macOS: version("26.0"), systemLanguage: "fr-FR")
        #expect(fr.systemSettings == "System Settings")
        #expect(table.names(macOS: version("26.0"), systemLanguage: "") == fr)
    }

    /// ADR 0315: macOS 12 has System Preferences, with its own pane names and URL anchors; 13 and 14 have
    /// System Settings with Login Items under General.
    @Test func macOS12NamesAndOpensSystemPreferences() throws {
        let table = try Self.shipped()
        let english = table.names(macOS: version("12.7.6"), systemLanguage: "en-US")
        #expect(english.systemSettings == "System Preferences")
        #expect(english.privacySecurity == "Security & Privacy > Privacy")
        #expect(english.usersGroups == "Users & Groups")
        #expect(english.loginItems == "Login Items")
        #expect(table.names(macOS: version("12.0"), systemLanguage: "vi-VN").systemSettings == "Tùy chọn Hệ thống")
        #expect(
            table.deepLink(.keyboard, macOS: version("12.6"))?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.keyboard")
        #expect(
            table.deepLink(.loginItems, macOS: version("12.6"))?.absoluteString
                == "x-apple.systempreferences:com.apple.preferences.users")
        #expect(
            table.deepLink(.accessibility, macOS: version("12.6"))?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// PRD-R64, decision 0005 Q37: every macOS 12 name as Apple's localization tables of macOS 12.7.6 (21H1320)
    /// spell it (Security.prefPane, Keyboard.prefPane and its IntlTexts sub-pane, Accounts.prefPane, System
    /// Preferences.app; docs/runbooks/vm-test-lab.md section 10). Vietnamese capitalises "Đầu vào" and "Đăng nhập".
    @Test func macOS12NamesMatchTheSystemTables() throws {
        let table = try Self.shipped()
        #expect(
            table.names(macOS: version("12.7.6"), systemLanguage: "vi-VN")
                == SystemPaneNames(
                    systemSettings: "Tùy chọn Hệ thống", privacySecurity: "Bảo mật & Quyền riêng tư > Quyền riêng tư",
                    accessibility: "Trợ năng", inputMonitoring: "Giám sát Đầu vào", keyboard: "Bàn phím",
                    textReplacements: "Văn bản", usersGroups: "Người dùng & Nhóm", loginItems: "Mục Đăng nhập"))
        #expect(
            table.names(macOS: version("12.7.6"), systemLanguage: "en-US")
                == SystemPaneNames(
                    systemSettings: "System Preferences", privacySecurity: "Security & Privacy > Privacy",
                    accessibility: "Accessibility", inputMonitoring: "Input Monitoring", keyboard: "Keyboard",
                    textReplacements: "Text", usersGroups: "Users & Groups", loginItems: "Login Items"))
    }

    /// PRD-R64, PLT-R701: every macOS 27 name as Apple's localization tables of macOS 27.2 (26B123) spell it
    /// (System Settings.app and the SecurityPrivacyExtension, KeyboardSettings, GeneralSettings and LoginItems
    /// extensions). "Login Items & Extensions" is "Mục đăng nhập & Phần mở rộng" in Vietnamese.
    @Test func macOS27NamesMatchTheSystemTables() throws {
        let table = try Self.shipped()
        #expect(
            table.names(macOS: version("27.2"), systemLanguage: "vi-VN")
                == SystemPaneNames(
                    systemSettings: "Cài đặt hệ thống", privacySecurity: "Quyền riêng tư & Bảo mật",
                    accessibility: "Điều khiển thiết bị và truy cập dữ liệu", inputMonitoring: "Giám sát đầu vào",
                    keyboard: "Bàn phím", textReplacements: "Thay thế văn bản", usersGroups: "Cài đặt chung",
                    loginItems: "Mục đăng nhập & Phần mở rộng"))
        #expect(
            table.names(macOS: version("27.2"), systemLanguage: "en-US")
                == SystemPaneNames(
                    systemSettings: "System Settings", privacySecurity: "Privacy & Security",
                    accessibility: "Device Control and Data Access", inputMonitoring: "Input Monitoring",
                    keyboard: "Keyboard", textReplacements: "Text Replacements", usersGroups: "General",
                    loginItems: "Login Items & Extensions"))
        // macOS 15 to 26 have no lab VM; they carry the macOS 27.2 spelling of the pane that macOS 15 introduced.
        #expect(
            table.names(macOS: version("15.0"), systemLanguage: "vi").loginItems == "Mục đăng nhập & Phần mở rộng")
    }

    @Test func macOS13And14UseSystemSettings() throws {
        let table = try Self.shipped()
        for macOS in ["13.0", "14.7"] {
            let names = table.names(macOS: version(macOS), systemLanguage: "en")
            #expect(names.systemSettings == "System Settings")
            #expect(names.privacySecurity == "Privacy & Security")
            #expect(names.usersGroups == "General")
            #expect(names.loginItems == "Login Items")
            #expect(
                table.deepLink(.loginItems, macOS: version(macOS))?.absoluteString
                    == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        }
        #expect(table.names(macOS: version("15.0"), systemLanguage: "en").loginItems == "Login Items & Extensions")
    }

    @Test func everyPaneHasADeepLinkOnEverySupportedVersion() throws {
        let table = try Self.shipped()
        for macOS in ["12.0", "12.7", "13.0", "14.6", "15.0", "26.5", "27.0", "28.0"] {
            for pane in SystemPane.allCases {
                let link = try #require(table.deepLink(pane, macOS: version(macOS)), "\(pane) on \(macOS)")
                #expect(link.scheme == "x-apple.systempreferences")
            }
        }
    }

    @Test func versionsOutsideEveryRangeUseTheNearestEntry() throws {
        let table = try SystemPaneTable(resource: Data(Self.fixture.utf8))
        #expect(table.names(macOS: version("14.0"), systemLanguage: "en").accessibility == "Old")
        #expect(table.names(macOS: version("16.0"), systemLanguage: "en").accessibility == "Old")
        #expect(table.names(macOS: version("19.0"), systemLanguage: "en").accessibility == "New")
        #expect(table.deepLink(.loginItems, macOS: version("19.0")) == nil)
    }

    @Test func malformedResourcesAreRejected() {
        #expect(throws: SystemPaneTableError.unsupportedSchema(2)) {
            try SystemPaneTable(resource: Data(#"{"schemaVersion":2,"entries":[]}"#.utf8))
        }
        #expect(throws: SystemPaneTableError.noEntries) {
            try SystemPaneTable(resource: Data(#"{"schemaVersion":1,"entries":[]}"#.utf8))
        }
        let noEnglish = Self.fixture.replacingOccurrences(of: "\"en\"", with: "\"de\"")
        #expect(throws: SystemPaneTableError.missingEnglishNames(entry: 0)) {
            try SystemPaneTable(resource: Data(noEnglish.utf8))
        }
        let badLink = Self.fixture.replacingOccurrences(of: "x-apple.systempreferences:old", with: "no scheme")
        #expect(throws: SystemPaneTableError.invalidDeepLink(entry: 0, pane: "accessibility")) {
            try SystemPaneTable(resource: Data(badLink.utf8))
        }
        #expect(throws: (any Error).self) { try SystemPaneTable(resource: Data("[]".utf8)) }
    }

    @Test func primaryLanguageSubtag() {
        #expect(SystemPaneTable.primaryLanguage("vi-VN") == "vi")
        #expect(SystemPaneTable.primaryLanguage("en_GB") == "en")
        #expect(SystemPaneTable.primaryLanguage("zh-Hant-TW") == "zh")
        #expect(SystemPaneTable.primaryLanguage("VI") == "vi")
    }

    static let fixture = """
        {"schemaVersion":1,"entries":[
          {"macOS":{"min":"15.0","max":"16.0"},
           "names":{"en":{"systemSettings":"S","privacySecurity":"P","accessibility":"Old","inputMonitoring":"I",
                          "keyboard":"K","textReplacements":"T","usersGroups":"U","loginItems":"L"}},
           "deepLinks":{"accessibility":"x-apple.systempreferences:old"}},
          {"macOS":{"min":"18.0","max":"18.9"},
           "names":{"en":{"systemSettings":"S","privacySecurity":"P","accessibility":"New","inputMonitoring":"I",
                          "keyboard":"K","textReplacements":"T","usersGroups":"U","loginItems":"L"}},
           "deepLinks":{}}
        ]}
        """
}
