// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Catalog test for the four W2-B String Catalogs (PRD-R62, PRD-R66, ADR 0310): every key in vi and en with
// matching format arguments, no empty values, no hard-coded brand, no dashes, every key the code uses present
// and no dead copy; copy that 03-product.md drafts is verbatim; every control of the Settings window has a
// VoiceOver label and hint and is a focusable control in App/Sources/Settings.

import AppModel
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct SettingsCatalogStringTests {
    static func referencedKeys() -> [StringTable: Set<String>] {
        func controls<C: AccessibleControl>(_ type: C.Type) -> [String] {
            type.allCases.flatMap { [$0.accessibilityLabelKey, $0.accessibilityHintKey] }
        }
        return [
            .settings: Set(SettingsText.allCases.map(\.rawValue) + controls(SettingsControl.self)),
            .macros: Set(MacrosText.allCases.map(\.rawValue) + controls(MacrosControl.self)),
            .apps: Set(AppsText.allCases.map(\.rawValue) + controls(AppsControl.self)),
            .support: Set(SupportText.allCases.map(\.rawValue) + controls(SupportControl.self)),
        ]
    }

    @Test(arguments: SettingsCatalogs.owned)
    func everyKeyHasViAndEnWithMatchingArguments(table: StringTable) throws {
        let catalog = try Catalog(table: table)
        #expect(catalog.sourceLanguage == "vi")
        #expect(!catalog.entries.isEmpty)
        for (key, entry) in catalog.entries {
            let vi = try #require(entry.values["vi"], "\(table.rawValue): \(key) has no vi value")
            let en = try #require(entry.values["en"], "\(table.rawValue): \(key) has no en value")
            #expect(!vi.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty vi")
            #expect(!en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty en")
            #expect(FormatSpecifiers.of(vi) == FormatSpecifiers.of(en), "\(table.rawValue): \(key) arguments differ")
        }
    }

    @Test(arguments: SettingsCatalogs.owned)
    func noBrandLiteralsNoDashesNoSudo(table: StringTable) throws {
        let catalog = try Catalog(table: table)
        let brand = try BrandFiles.values()
        for (key, entry) in catalog.entries {
            for value in entry.values.values {
                for literal in [brand.displayName, brand.siteHost, brand.bundleID] {
                    #expect(!value.contains(literal), "\(key) hard-codes \(literal); pass the brand as an argument")
                }
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"), "\(key) contains a dash")
                #expect(!value.lowercased().contains("sudo"), "\(key): PLT-R741 forbids suggesting sudo")
            }
        }
    }

    @Test(arguments: SettingsCatalogs.owned)
    func everyReferencedKeyExistsAndNoCopyIsDead(table: StringTable) throws {
        let catalog = try Catalog(table: table)
        let referenced = Self.referencedKeys()[table] ?? []
        let present = Set(catalog.entries.keys)
        #expect(referenced.subtracting(present).sorted() == [], "missing in \(table.rawValue)")
        #expect(present.subtracting(referenced).sorted() == [], "unused in \(table.rawValue)")
    }

    @Test func paneNamesAndDraftCopyAreVerbatimFromTheSpec() throws {
        // PRD-R24 pane names, PRD-R26 reset, PRD-R43 empty states, PRD-R34/R35/R37 labels, PRD-R59 donation line.
        let l = try Localizers()
        let expected: [(String, String, StringTable, String)] = [
            ("settings.pane.general", "Chung", .settings, "General"),
            ("settings.pane.typing", "Gõ phím", .settings, "Typing"),
            ("settings.pane.apps", "Ứng dụng", .settings, "Apps"),
            ("settings.pane.macros", "Gõ tắt", .settings, "Macros"),
            ("settings.pane.aboutSupport", "Giới thiệu & Hỗ trợ", .settings, "About & Support"),
            ("settings.advanced", "Tùy chọn nâng cao", .settings, "Advanced options"),
            ("macros.empty", "Chưa có gõ tắt nào. Ví dụ: gõ \"vn\" để ra \"Việt Nam\".", .macros, ""),
            ("macros.add", "Thêm gõ tắt", .macros, ""),
            ("macros.import", "Nhập từ tệp...", .macros, ""),
            ("macros.import.chooseOther", "Chọn tệp khác", .macros, ""),
            ("apps.empty", "Các ứng dụng bạn gõ sẽ hiện ở đây để bạn đặt quy tắc riêng.", .apps, ""),
            ("apps.rule.remember", "Nhớ lựa chọn", .apps, ""),
            ("apps.rule.alwaysEnglish", "Luôn tiếng Anh", .apps, ""),
            ("apps.rule.alwaysVietnamese", "Luôn tiếng Việt", .apps, ""),
            ("apps.rule.ignore", "Bỏ qua", .apps, ""),
            ("apps.status.works", "Hoạt động tốt", .apps, "Works"),
            ("apps.status.worksWithNotes", "Hoạt động, có lưu ý", .apps, "Works with notes"),
            ("apps.status.notVerified", "Chưa kiểm tra", .apps, "Not yet verified"),
            ("apps.status.knownLimitation", "Hạn chế đã biết", .apps, "Known limitation"),
            ("apps.report", "Báo lỗi với ứng dụng này...", .apps, ""),
            ("apps.compat.title", "Chế độ tương thích", .apps, ""),
            ("support.channel.title", "Kênh cập nhật", .support, "Update channel"),
            ("support.channel.stable", "Ổn định", .support, "Stable"),
            ("support.checkNow", "Kiểm tra cập nhật...", .support, ""),
            ("support.reportProblem", "Báo lỗi...", .support, ""),
            ("settings.typing.keepAsTyped.title", "Giữ nguyên như đã gõ", .settings, ""),
            ("settings.typing.keepVietnamese.title", "Giữ là tiếng Việt", .settings, ""),
        ]
        for (key, vi, table, en) in expected {
            #expect(l.vi.string(key, table: table) == vi, "\(key)")
            if !en.isEmpty { #expect(l.en.string(key, table: table) == en, "\(key)") }
        }
        #expect(l.vi.string(SettingsText.resetPane).hasPrefix("Khôi phục mặc định"))
        #expect(
            l.vi.format(SupportText.donateBody, "{{AppName}}")
                == "{{AppName}} miễn phí và sẽ luôn miễn phí. Nếu thấy có ích, bạn có thể ủng hộ để Kal có thêm thời gian làm tiếp."
        )
        // PRD-R43 draft, whole sentence: the reason continues the sentence after "Dòng 12:" in lower case.
        let row = MacroImportRow(line: 12, shortcut: "x", expansion: "", issue: .emptyExpansion)
        #expect(
            MacroImportRefusal.invalidFile(firstInvalid: row).message(l.vi)
                == "Tệp này không đúng định dạng. Dòng 12: thiếu phần nội dung gõ tắt.")
        #expect(
            MacroImportRefusal.invalidFile(firstInvalid: row).message(l.en)
                == "This file is not in the expected format. Line 12: the macro text is missing.")
        #expect(l.vi.string(MacrosText.issueEmptyExpansion) == "Thiếu phần nội dung gõ tắt.")
    }

    @Test func recoveredFromBackupCopyDoesNotSayChangesAreLost() throws {
        // W1-B: the recovered state is already saved, so the informational notice must not ask for confirmation.
        let l = try Localizers()
        for localizer in [l.vi, l.en] {
            let text = localizer.string(SettingsText.noticeRecovered).lowercased()
            #expect(!text.contains("mất") && !text.contains("lost") && !text.contains("xác nhận"))
            #expect(!text.contains("confirm"))
        }
        #expect(l.vi.string(SettingsText.noticeCorrupt).contains(l.vi.string(SettingsText.noticeUseDefaults)))
    }

    // MARK: App sources (App/Sources/Settings)

    static let settingsSources = "App/Sources/Settings"

    static func sourceFiles() throws -> [(name: String, lines: [String])] {
        let directory = RepoPaths.url(settingsSources)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    static var control: Regex<(Substring, Substring)> {
        /\b(Button|TextField|Toggle|Picker|Link|Menu|DisclosureGroup|TextEditor)\(/
    }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// True when the control opened on `lines[start]` carries its own `settingsAccessibility(` modifier: on the
    /// same line, or on a `.modifier` line at the control's indentation (after a trailing closure) or one level in
    /// (a chain), with no other control at that depth or shallower in between (a nested or following control's
    /// modifier does not count). The search stops where the enclosing block closes.
    static func hasOwnAccessibility(_ lines: [String], at start: Int) -> Bool {
        let opening = lines[start]
        if let range = opening.firstMatch(of: control)?.range,
            opening[range.upperBound...].contains("settingsAccessibility(")
        {
            return true
        }
        let base = indentation(opening)
        var shallowestControl = Int.max
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = indentation(line)
            if indent < base { return false }
            if trimmed.hasPrefix(".settingsAccessibility("), indent <= base + 4, indent < shallowestControl {
                return true
            }
            if line.contains(control) { shallowestControl = min(shallowestControl, indent) }
            if indent == base, !trimmed.hasPrefix("."), !trimmed.hasPrefix("}"), !trimmed.hasPrefix(")") {
                return false
            }
        }
        return false
    }

    @Test func everyControlInTheSettingsWindowHasLabelAndHint() throws {
        // PRD-R66: each SwiftUI control, alert buttons with a role included, carries its own
        // `settingsAccessibility(...)` (label and hint from a W2-B catalog).
        for (name, lines) in try Self.sourceFiles() {
            for (index, line) in lines.enumerated() where line.contains(Self.control) {
                #expect(Self.hasOwnAccessibility(lines, at: index), "\(name):\(index + 1) has no label and hint")
            }
        }
    }

    @Test func accessibilityScanRejectsAnUnlabelledControlNextToALabelledOne() {
        // The scan itself: a control without the modifier just above a labelled one, or one whose only nearby
        // modifier belongs to a nested control, is caught; role buttons are checked too.
        let siblings = [
            "        Button(role: .cancel, action: cancel) {",
            "            Text(verbatim: title)",
            "        }",
            "        Button(action: confirm) { Text(verbatim: title) }",
            "            .settingsAccessibility(SettingsControl.resetConfirm, localizer)",
        ]
        #expect(!Self.hasOwnAccessibility(siblings, at: 0))
        #expect(Self.hasOwnAccessibility(siblings, at: 3))
        let nested = [
            "        DisclosureGroup(isExpanded: $open) {",
            "            Toggle(isOn: $flag) { Text(verbatim: title) }",
            "                .settingsAccessibility(SettingsControl.resetConfirm, localizer)",
            "        } label: {",
            "            Text(verbatim: title)",
            "        }",
            "        .padding()",
            "    }",
        ]
        #expect(!Self.hasOwnAccessibility(nested, at: 0))
        #expect(Self.hasOwnAccessibility(nested, at: 1))
        let parentLabelled = nested.prefix(6) + ["        .settingsAccessibility(SettingsControl.advanced, localizer)"]
        #expect(Self.hasOwnAccessibility(Array(parentLabelled), at: 0))
    }

    @Test func everyDeclaredControlIsReachableInTheWindow() throws {
        // PRD-R67: every control the catalogs label is used by a view, and no view takes a control out of the
        // keyboard loop (`.focusable(false)`) or hides it from VoiceOver.
        let source = try Self.sourceFiles().flatMap(\.lines).joined(separator: "\n")
        // Notice buttons get their control from `StoreNoticePresentation.Action.control` (ShellCore).
        let actions: [StoreNoticePresentation.Action] = [
            .dismiss(.settings), .useDefaults(.settings), .leaveSafeMode, .report, .resetAll,
        ]
        let noticeControls = source.contains("action.control") ? Set(actions.map(\.control)) : []
        func check<C: AccessibleControl>(_ type: C.Type, prefix: String) {
            for control in type.allCases {
                if let control = control as? SettingsControl, noticeControls.contains(control) { continue }
                #expect(
                    source.contains("\(prefix).\(control.rawValue)"), "\(prefix).\(control.rawValue) is never shown")
            }
        }
        check(SettingsControl.self, prefix: "SettingsControl")
        check(MacrosControl.self, prefix: "MacrosControl")
        check(AppsControl.self, prefix: "AppsControl")
        check(SupportControl.self, prefix: "SupportControl")
        #expect(!source.contains(".focusable(false)"))
        #expect(!source.contains("accessibilityHidden(true)\n            Button"))
    }

    @Test func settingsSourcesHaveNoLiteralProductCopy() throws {
        // ADR 0310: copy comes from the catalogs through `Localizer`, never `Text("...")`.
        let pattern =
            /(Text|Button|Toggle|Label|Link)\(\s*"[^"]+"|\.help\(\s*"|setAccessibility(Label|Help)\(\s*"|title:\s*"[^"]+"/
        for (name, lines) in try Self.sourceFiles() {
            for (index, line) in lines.enumerated() {
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                #expect(code.firstMatch(of: pattern) == nil, "\(name):\(index + 1)")
            }
        }
    }

    @Test func animationsRespectReduceMotion() throws {
        // PRD-R67: any animation in the Settings window is gated on Reduce Motion.
        for (name, lines) in try Self.sourceFiles() {
            let source = lines.joined(separator: "\n")
            if source.contains("withAnimation") || source.contains(".animation(") {
                #expect(source.contains("accessibilityReduceMotion"), "\(name) animates without Reduce Motion")
            }
        }
    }
}

@Suite struct SettingsLocalizationHelperTests {
    @Test func keysResolveThroughTheirOwnTables() throws {
        #expect(SettingsText.table == .settings && SettingsControl.table == .settings)
        #expect(MacrosText.table == .macros && MacrosControl.table == .macros)
        #expect(AppsText.table == .apps && AppsControl.table == .apps)
        #expect(SupportText.table == .support && SupportControl.table == .support)
        let l = try Localizers()
        #expect(l.vi.string(AppsText.ruleIgnore) == "Bỏ qua")
        #expect(l.en.accessibilityLabel(AppsControl.rowReport) == "Report a problem with this app")
        #expect(l.vi.accessibilityHint(SupportControl.checkNow) == "Kiểm tra bản mới ngay bây giờ.")
        #expect(SettingsControl.panePicker.accessibilityLabelKey == "settings.control.panePicker.accessibilityLabel")
        let text = CatalogText(key: "support.donate.title", table: .support)
        #expect(text == CatalogText(SupportText.donateTitle))
        #expect(l.en.format(text, "App") == "Support App")
        #expect(l.vi.string(CatalogText(MacrosText.add)) == "Thêm gõ tắt")
        #expect(SettingsSymbol.info != SettingsSymbol.infoFill)
    }

    @Test func importSummaryNamesSettingsWithoutAVisibleTitle() throws {
        let l = try Localizers()
        #expect(SettingNames.name(forKey: "typingMethod", l.vi) == "Kiểu gõ")
        #expect(SettingNames.name(forKey: "firstSeenAppMode", l.vi) == "Chế độ cho ứng dụng mới")
        #expect(SettingNames.name(forKey: "macrosInEnglishMode", l.en) == "Macros in English mode")
        #expect(SettingNames.name(forKey: "optedInRules", l.en) == "Compatibility rules you turned on")
        #expect(SettingNames.name(forKey: "somethingNew", l.vi) == "somethingNew")
        #expect(ListFormat.join(["a", "b", "c"], l.en) == "a, b, and c")
    }
}
