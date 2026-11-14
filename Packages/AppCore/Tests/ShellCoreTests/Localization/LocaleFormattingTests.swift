// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R65: dates, numbers and versions follow the selected interface language, not the macOS language, through
// the shipped catalogs; PRD-R63: a language change re-renders the copy of every table without a restart.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct LocaleFormattingTests {
    let bundle: TemporaryAppBundle
    let vi: Localizer
    let en: Localizer

    init() throws {
        bundle = try TemporaryAppBundle(catalogs: StringTable.allCases)
        vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        en = Localizer(language: .english, appBundle: bundle.bundle)
    }

    @Test func countsInCopyAreGroupedPerLanguage() {
        // Integer arguments go through `String(format:locale:)`, which groups digits in the selected language.
        #expect(vi.format(MacrosText.count, 1_500) == "Số gõ tắt: 1.500")
        #expect(en.format(MacrosText.count, 1_500) == "Macros: 1,500")
        #expect(vi.format(SettingsText.importMacros, 1_200, 3, 0) == "Gõ tắt: 1.200 mới, 3 trùng, 0 không hợp lệ")
        #expect(en.format(SettingsText.importMacros, 1_200, 3, 0) == "Macros: 1,200 new, 3 duplicates, 0 invalid")
    }

    @Test func calendarDaysOfTheCompatibilityMatrixFollowTheLanguage() throws {
        // `lastVerified` is an ISO day in compat-matrix.json; the detail sheet shows it in the interface language.
        let utc = try #require(TimeZone(identifier: "UTC"))
        let viDay = vi.formatDay(iso: "2026-11-01", timeZone: utc)
        let enDay = en.formatDay(iso: "2026-11-01", timeZone: utc)
        #expect(enDay == "November 1, 2026")
        #expect(viDay.contains("2026") && viDay.contains("11") && !viDay.contains("November"))
        #expect(viDay != "2026-11-01")
        // Same style as other dates of the app.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(
            viDay
                == date.formatted(
                    Date.FormatStyle(
                        date: .long, time: .omitted, locale: vi.locale, calendar: calendar, timeZone: utc)))
        let line = vi.format(AppsText.detailLastVerified, viDay)
        #expect(line.hasPrefix("Kiểm tra lần cuối: ") && line.hasSuffix(viDay))
    }

    @Test func textThatIsNotADayIsShownUnchanged() {
        for text in ["2026-02-30", "2026-13-01", "26-11-01", "2026-11-01T00:00:00Z", "soon", ""] {
            #expect(en.formatDay(iso: text) == text)
        }
    }

    @Test func dayIsTheSameCalendarDayInAnyTimeZone() throws {
        for identifier in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Ho_Chi_Minh"] {
            let zone = try #require(TimeZone(identifier: identifier))
            #expect(en.formatDay(iso: "2026-11-01", timeZone: zone) == "November 1, 2026", "\(identifier)")
        }
    }

    @Test func versionLineKeepsTheVersionAndNamesItInTheLanguage() {
        // Version strings are not localised numbers; the words around them are.
        #expect(vi.format(SupportText.version, "1.2.0", "45") == "Phiên bản 1.2.0 (45)")
        #expect(en.format(SupportText.version, "1.2.0", "45") == "Version 1.2.0 (45)")
    }

    @MainActor
    @Test func languageChangeReRendersEveryTableWithoutRestart() {
        // PRD-R63: one observable model feeds every window; each table switches with it.
        let model = InterfaceLanguageModel(language: .vietnamese, appBundle: bundle.bundle)
        var samples: [(StringTable, String, String, String)] = [
            (.common, CommonText.back.rawValue, "Quay lại", "Back"),
            (.menu, MenuText.settings.rawValue, "Cài đặt...", "Settings..."),
            (.status, StatusText.actionLearnMore.rawValue, "Tìm hiểu thêm", "Learn more"),
            (.onboarding, OnboardingText.doneStart.rawValue, "Bắt đầu", "Start"),
            (.settings, SettingsText.paneGeneral.rawValue, "Chung", "General"),
            (.macros, MacrosText.sortTitle.rawValue, "Sắp xếp", "Sort"),
            (.apps, AppsText.columnRule.rawValue, "Quy tắc", "Rule"),
            (.support, SupportText.privacyTitle.rawValue, "Quyền riêng tư", "Privacy"),
            (.diagnostics, DiagnosticsText.windowTitle.rawValue, "Chẩn đoán", "Diagnostics"),
            (.composition, CompositionText.safeModeLater.rawValue, "Để sau", "Not Now"),
            (.updates, "updates.failed.retry", "Thử lại", "Try Again"),
        ]
        #if DEV_RECORDER
        // PLT-R904A: the dev recorder's table exists in Debug builds only.
        samples.append((.devRecorder, DevRecorderText.resume.rawValue, "Tiếp tục ghi", "Resume recording"))
        #endif
        #expect(Set(samples.map(\.0)) == Set(StringTable.allCases))
        for (table, key, viText, _) in samples { #expect(model.localizer.string(key, table: table) == viText) }
        model.select(.english)
        for (table, key, _, enText) in samples { #expect(model.localizer.string(key, table: table) == enText) }
        #expect(model.localizer.formatNumber(1_000) == "1,000")
        model.select(.vietnamese)
        #expect(model.localizer.formatNumber(1_000) == "1.000")
    }
}
