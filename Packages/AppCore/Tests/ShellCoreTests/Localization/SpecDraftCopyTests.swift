// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every Vietnamese copy draft in spec/03-product.md, verbatim, in one list (PRD-R62, PRD-R40, W2-F copy
// review): menu (PRD-R11), icon labels (PRD-R10), switch HUD (PRD-R12, PRD-R66), status lines and error states
// (PRD-R43), the D-table setting labels (section 4) and pane names (PRD-R24), the per-setting example (PRD-R25),
// Apps (PRD-R34 to R37), the eight onboarding screens (PRD-R40, PRD-R42), the bug report (PRD-R47) and the
// donation line (PRD-R59). Spec placeholders are passed as the format arguments, so the expected text reads
// exactly as in the spec. Where the spec gives an English label too (PRD-R10, section 4, PRD-R35), English is
// checked as well; elsewhere English is a translation and not pinned.

import Foundation
import Testing

@testable import ShellCore

@Suite struct SpecDraftCopyTests {
    struct Draft: Sendable {
        var table: StringTable
        var key: String
        var arguments: [String] = []
        var vi: String
        var en: String? = nil
    }

    static let app = "{{AppName}}"
    /// The name with its trademark sign where the spec writes it (Pa, 15/11/2026).
    static let appTM = "{{AppNameTM}}"

    static let menu: [Draft] = [
        Draft(table: .menu, key: "menu.mode.vietnamese", vi: "Tiếng Việt"),
        Draft(table: .menu, key: "menu.mode.english", vi: "Tiếng Anh"),
        Draft(table: .menu, key: "menu.method.telex", vi: "Telex"),
        Draft(table: .menu, key: "menu.method.vni", vi: "VNI"),
        Draft(table: .menu, key: "menu.perApp.title", arguments: ["<App name>"], vi: "Với <App name>"),
        Draft(table: .menu, key: "menu.perApp.rule.remember", vi: "Nhớ lựa chọn"),
        Draft(table: .menu, key: "menu.perApp.rule.alwaysEnglish", vi: "Luôn tiếng Anh"),
        Draft(table: .menu, key: "menu.perApp.rule.alwaysVietnamese", vi: "Luôn tiếng Việt"),
        Draft(table: .menu, key: "menu.perApp.rule.ignore", vi: "Bỏ qua ứng dụng này"),
        Draft(table: .menu, key: "menu.perApp.report", vi: "Báo lỗi với ứng dụng này..."),
        Draft(table: .menu, key: "menu.macros", vi: "Viết tắt..."),
        Draft(table: .menu, key: "menu.settings", vi: "Cài đặt..."),
        Draft(table: .menu, key: "menu.reportProblem", vi: "Báo lỗi..."),
        Draft(table: .menu, key: "menu.checkForUpdates", vi: "Kiểm tra cập nhật..."),
        Draft(table: .menu, key: "menu.donate", arguments: [app], vi: "Ủng hộ {{AppName}}..."),
        Draft(table: .menu, key: "menu.quit", arguments: [app], vi: "Thoát {{AppName}}"),
        // PRD-R10 (vi / en).
        Draft(
            table: .menu, key: "icon.vietnamese.accessibilityLabel", vi: "Đang gõ tiếng Việt",
            en: "Vietnamese typing on"),
        Draft(table: .menu, key: "icon.english.accessibilityLabel", vi: "Đang gõ tiếng Anh", en: "English typing"),
        Draft(
            table: .menu, key: "icon.ignoredApp.accessibilityLabel", vi: "Bỏ qua ứng dụng này",
            en: "Ignored in this app"),
        Draft(
            table: .menu, key: "icon.secureInputVietnamese.accessibilityLabel", vi: "Ô bảo mật đang bật",
            en: "Secure input active"),
        Draft(
            table: .menu, key: "icon.secureInputEnglish.accessibilityLabel", vi: "Ô bảo mật đang bật",
            en: "Secure input active"),
        Draft(
            table: .menu, key: "icon.paused.accessibilityLabel", vi: "Tạm dừng: đang dùng bộ gõ khác",
            en: "Paused: another input source is active"),
        // Decision 0005, 15/11/2026: the permission state has its own warning badge; the slash is the other fail-open.
        Draft(
            table: .menu, key: "icon.permissionMissing.accessibilityLabel",
            vi: "Cảnh báo: chưa gõ được, cần cấp quyền", en: "Warning: not working, permission needed"),
        Draft(
            table: .menu, key: "icon.notWorking.accessibilityLabel",
            vi: "Chưa gõ được: mở menu để xem cách khắc phục", en: "Not working: open the menu to see how to fix it"),
        // PRD-R12 glyphs, PRD-R66 announcement.
        Draft(table: .menu, key: "hud.switch.vietnamese.glyph", vi: "V", en: "V"),
        Draft(table: .menu, key: "hud.switch.english.glyph", vi: "E", en: "E"),
        Draft(table: .menu, key: "hud.switch.vietnamese.announcement", vi: "Tiếng Việt"),
        Draft(table: .menu, key: "hud.switch.english.announcement", vi: "Tiếng Anh"),
    ]

    static let status: [Draft] = [
        Draft(
            table: .status, key: "status.noPermission", arguments: [app],
            vi: "Chưa có quyền nhận phím gõ. {{AppName}} đang tạm dừng để không ảnh hưởng bàn phím."),
        Draft(table: .status, key: "status.action.grantPermission", vi: "Cấp quyền..."),
        Draft(
            table: .status, key: "status.secureInput.holder", arguments: ["{{HolderApp}}"],
            vi:
                "{{HolderApp}} đang bật chế độ nhập bảo mật, nên mọi bộ gõ đều tạm dừng. Thường do một ô mật khẩu còn mở."
        ),
        Draft(table: .status, key: "status.action.showHolder", arguments: ["{{HolderApp}}"], vi: "Hiện {{HolderApp}}"),
        Draft(
            table: .status, key: "status.action.secureInputHelp.unknownHolder",
            vi: "Không xác định được ứng dụng. Hướng dẫn..."),
        Draft(table: .status, key: "status.tapReenabled", vi: "Bộ gõ vừa bị macOS tạm ngắt và đã chạy lại."),
        Draft(table: .status, key: "status.action.reportProblem", vi: "Báo lỗi..."),
        Draft(
            table: .status, key: "status.nonLatinSource", arguments: ["{{SourceName}}", app],
            vi: "Đang dùng bàn phím {{SourceName}}. {{AppName}} tạm dừng."),
        Draft(table: .status, key: "status.action.learnMore", vi: "Tìm hiểu thêm"),
        Draft(table: .updates, key: "updates.failed.title", vi: "Không tải được bản cập nhật."),
        Draft(
            table: .updates, key: "updates.failed.body", arguments: ["{{Version}}"],
            vi: "Bạn vẫn đang dùng bản {{Version}}, mọi thứ hoạt động bình thường."),
        Draft(table: .updates, key: "updates.failed.retry", vi: "Thử lại"),
        Draft(table: .updates, key: "updates.failed.download", vi: "Tải từ trang web"),
        Draft(table: .macros, key: "macros.import.chooseOther", vi: "Chọn file khác"),
        Draft(
            table: .macros, key: "macros.empty", vi: "Chưa có mục viết tắt nào. Ví dụ: gõ \"vn\" để ra \"Việt Nam\"."),
        Draft(table: .macros, key: "macros.add", vi: "Thêm viết tắt"),
        Draft(table: .macros, key: "macros.import", vi: "Nhập từ file..."),
        Draft(table: .apps, key: "apps.empty", vi: "Các ứng dụng bạn gõ sẽ hiện ở đây để bạn đặt quy tắc riêng."),
        // PLT-R397B: the Diagnostics window's explanation of a secure-input bursts event.
        Draft(
            table: .diagnostics, key: "diagnostics.health.secureInputBursts.explanation", arguments: [app],
            vi:
                "Có ứng dụng liên tục bật rồi tắt chế độ nhập bảo mật (Secure Input) trong lúc bạn gõ, nên vài phím có "
                + "thể không tới được {{AppName}}. Hãy thử thoát các bộ gõ khác, trình quản lý mật khẩu hoặc ứng dụng "
                + "chạy nền mới cài để tìm ra ứng dụng đó.",
            en:
                "An app keeps turning Secure Input on and off while you type, so some keys may not reach {{AppName}}. "
                + "Try quitting other input methods, password managers or recently installed background apps to find "
                + "it."),
    ]

    /// Section 4 (UI label vi / en), PRD-R24 pane names and the Advanced disclosure, PRD-R25 example.
    static let settings: [Draft] = [
        Draft(table: .settings, key: "settings.typing.method.title", vi: "Kiểu gõ", en: "Typing method"),
        Draft(table: .settings, key: "settings.typing.tone.title", vi: "Kiểu đặt dấu", en: "Tone placement"),
        Draft(
            table: .settings, key: "settings.typing.englishRestore.title", vi: "Tự khôi phục từ tiếng Anh",
            en: "Automatic English restore"),
        Draft(
            table: .settings, key: "settings.typing.standaloneW.title", vi: "Telex: w đứng riêng thành ư",
            en: "Telex: lone w becomes ư"),
        Draft(table: .settings, key: "settings.typing.brackets.title", vi: "Telex: phím [ ] thành ơ ư"),
        Draft(
            table: .settings, key: "settings.typing.restoreHotkey.title", vi: "Phím khôi phục từ vừa gõ",
            en: "Restore-last-word hotkey"),
        Draft(table: .macros, key: "macros.enabled.title", vi: "Viết tắt (macro)", en: "Macros"),
        Draft(
            table: .settings, key: "settings.name.macrosInEnglishMode", vi: "Viết tắt khi ở chế độ tiếng Anh",
            en: "Expand macros in English mode"),
        Draft(
            table: .settings, key: "settings.general.toggleHotkey.title", vi: "Phím chuyển Việt/Anh",
            en: "VI/EN toggle hotkey"),
        Draft(
            table: .settings, key: "settings.general.rememberPerApp.title", vi: "Nhớ Việt/Anh theo ứng dụng",
            en: "Remember VI/EN per app"),
        Draft(
            table: .settings, key: "settings.name.firstSeenAppMode", vi: "Chế độ cho ứng dụng mới",
            en: "Mode for an app seen for the first time"),
        Draft(
            table: .settings, key: "settings.general.switchIndicator.title", vi: "Hiện thông báo nhỏ khi chuyển",
            en: "Show switch indicator"),
        Draft(
            table: .settings, key: "settings.general.soundOnSwitch.title", vi: "Âm thanh khi chuyển",
            en: "Sound on switch"),
        Draft(
            table: .settings, key: "settings.general.clickIcon.title", vi: "Bấm biểu tượng để chuyển Việt/Anh",
            en: "Click menu bar icon to toggle"),
        Draft(
            table: .settings, key: "settings.general.openAtLogin.title", vi: "Khởi động cùng hệ thống",
            en: "Open at login"),
        Draft(
            table: .settings, key: "settings.general.interfaceLanguage.title", vi: "Ngôn ngữ giao diện",
            en: "Interface language"),
        Draft(
            table: .support, key: "support.autoCheck.title", vi: "Tự động kiểm tra cập nhật",
            en: "Check for updates automatically"),
        Draft(
            table: .support, key: "support.autoInstall.title", vi: "Tự động cài cập nhật",
            en: "Install updates automatically"),
        Draft(table: .support, key: "support.channel.title", vi: "Kênh cập nhật", en: "Update channel"),
        Draft(table: .settings, key: "settings.pane.general", vi: "Chung", en: "General"),
        Draft(table: .settings, key: "settings.pane.typing", vi: "Kiểu gõ", en: "Typing"),
        Draft(table: .settings, key: "settings.pane.apps", vi: "Ứng dụng", en: "Apps"),
        Draft(table: .settings, key: "settings.pane.macros", vi: "Viết tắt", en: "Macros"),
        Draft(table: .settings, key: "settings.pane.about", vi: "Giới thiệu", en: "About"),
        Draft(table: .settings, key: "settings.pane.support", vi: "Hỗ trợ", en: "Support"),
        Draft(table: .settings, key: "settings.pane.licences", vi: "Bản quyền", en: "Licences"),
        Draft(table: .settings, key: "settings.advanced", vi: "Tùy chọn nâng cao"),
        Draft(
            table: .settings, key: "settings.typing.englishRestore.explanation",
            vi: "Ví dụ: gõ text vẫn ra text, không thành tẽt."),
        // D28, D29 (section 4) and the PRD-R79 copy of the learned-words sheet.
        Draft(
            table: .settings, key: "settings.typing.learnCollision.title",
            vi: "Nhớ cách bạn chọn giữa từ tiếng Anh và tiếng Việt", en: "Learn which reading you choose"),
        Draft(
            table: .settings, key: "settings.typing.lookaheadRevision.title",
            vi: "Sửa lại từ trước khi từ sau cho biết ngôn ngữ",
            en: "Fix the previous word once the next word shows the language"),
        Draft(
            table: .settings, key: "settings.typing.learnCollision.explanation", arguments: [app],
            vi:
                "Khi bạn sửa một từ vừa là tiếng Anh vừa là tiếng Việt (as/á, car/cả), {{AppName}} ghi nhớ lựa chọn "
                + "đó cho lần sau. Chỉ lưu trên máy này."),
        Draft(table: .settings, key: "settings.typing.learnedChoices.show", vi: "Xem từ đã học..."),
        Draft(table: .settings, key: "settings.typing.learnedChoices.removeAll", vi: "Xóa tất cả..."),
        Draft(
            table: .settings, key: "settings.typing.learnedChoices.empty", arguments: [app],
            vi: "Chưa có từ nào. {{AppName}} học khi bạn sửa một từ bằng phím Escape."),
        // PRD-R78, PRD-R79 and PRD-R72 (amended 15/11/2026): the learned words could not be loaded (the sheet and
        // the import sheet; the import's count lines are pinned in LearnedChoicesPaneTests).
        Draft(
            table: .settings, key: "settings.typing.learnedChoices.unavailable", arguments: [app],
            vi: "Không tải được danh sách từ đã học. Mở lại {{AppName}} có thể khắc phục lỗi này."),
        Draft(
            table: .settings, key: "settings.import.learnedChoicesUnavailable", arguments: [app],
            vi:
                "Chưa nhập được từ đã học vì không tải được danh sách từ đã học. Mở lại {{AppName}} có thể khắc phục "
                + "lỗi này."),
        // PRD-R79 amended 15/11/2026 (retest item 21): from an empty field `tricky as hell` has no revision, so the
        // example starts with Vietnamese words.
        Draft(
            table: .settings, key: "settings.typing.lookaheadRevision.explanation",
            vi:
                "Ví dụ: gõ cái này tricky as hell thì á đổi lại thành as khi bạn gõ hell. Trong Terminal và trình "
                + "soạn mã, chỉ sửa chữ đầu dòng khi chữ sau là tiếng Việt (tar thử thành tả thử)."),
        // D30 and the never-correct list (1.1.0, PRD-R80, PRD-R81), with the Q10 words "từ viết hoa toàn bộ" /
        // "words in all capitals" (scripts/tests/test_correction_policy.py checks them against CorrectionPolicy).
        Draft(
            table: .settings, key: "settings.typing.typoCorrection.title", vi: "Tự sửa từ gõ nhầm",
            en: "Fix mistyped words"),
        Draft(
            table: .settings, key: "settings.typing.typoCorrection.explanation", arguments: [app],
            vi:
                "Gõ nhầm một từ tiếng Anh (androdi, gramar) thì {{AppName}} sửa thành từ đúng (android, grammar) khi "
                + "bạn gõ dấu cách. Không sửa từ tiếng Việt, từ viết hoa toàn bộ hay chữ gõ trong Terminal. Nhấn "
                + "Escape ngay sau đó để lấy lại từ bạn đã gõ.",
            en:
                "When you mistype an English word (androdi, gramar), {{AppName}} replaces it with the one word it can "
                + "be (android, grammar) as you type the space. Vietnamese words, words in all capitals and anything "
                + "typed in Terminal are never changed. Press Escape right after to get the word you typed back."),
        Draft(
            table: .settings, key: "settings.typing.typoCorrection.disabledSuffix",
            vi: "Bật Tự khôi phục từ tiếng Anh để dùng.", en: "Turn on Automatic English restore to use this."),
        Draft(table: .settings, key: "settings.typing.neverCorrect.title", vi: "Không tự sửa", en: "Never correct"),
        Draft(
            table: .settings, key: "settings.typing.neverCorrect.explanation", arguments: [app],
            vi:
                "Những từ {{AppName}} luôn giữ như bạn gõ, không sửa. Từ bạn lấy lại bằng phím Escape được thêm vào "
                + "đây.",
            en: "Words {{AppName}} always leaves as you typed them. A word you take back with Escape is added here."),
        Draft(
            table: .settings, key: "settings.typing.neverCorrect.invalid",
            vi: "Chỉ nhận chữ cái không dấu, không có số hay ký hiệu.",
            en: "Letters only, without marks, digits or symbols."),
        // PRD-R24 acceptance and PRD-R81: the entry field under each of the three lists.
        Draft(table: .settings, key: "settings.typing.list.placeholder", vi: "Thêm từ mới"),
        Draft(table: .settings, key: "settings.control.resetConfirm.accessibilityLabel", vi: "Khôi phục mặc định"),
        Draft(table: .apps, key: "apps.rule.remember", vi: "Nhớ lựa chọn"),
        Draft(table: .apps, key: "apps.rule.alwaysEnglish", vi: "Luôn tiếng Anh"),
        Draft(table: .apps, key: "apps.rule.alwaysVietnamese", vi: "Luôn tiếng Việt"),
        Draft(table: .apps, key: "apps.rule.ignore", vi: "Bỏ qua"),
        Draft(table: .apps, key: "apps.status.works", vi: "Hoạt động tốt", en: "Works"),
        Draft(table: .apps, key: "apps.status.worksWithNotes", vi: "Hoạt động, có lưu ý", en: "Works with notes"),
        Draft(table: .apps, key: "apps.status.notVerified", vi: "Chưa kiểm tra", en: "Not yet verified"),
        Draft(table: .apps, key: "apps.status.knownLimitation", vi: "Hạn chế đã biết", en: "Known limitation"),
        Draft(table: .apps, key: "apps.compat.title", vi: "Chế độ tương thích"),
        Draft(table: .apps, key: "apps.report", vi: "Báo lỗi với ứng dụng này..."),
        // PRD-R59, Pa's donation copy (15/11/2026): the marked name in the title and the first line.
        Draft(table: .support, key: "support.donate.title", arguments: [appTM], vi: "Ủng hộ {{AppNameTM}}"),
        Draft(
            table: .support, key: "support.donate.body", arguments: [appTM],
            vi:
                "{{AppNameTM}} miễn phí vĩnh viễn. Nếu bạn thấy hữu dụng, có thể mời Kal 1 ly cafe để có tinh thần phát triển thêm tính năng mới."
        ),
        Draft(
            table: .support, key: "support.donate.howTo", arguments: [app],
            vi:
                "Bạn có thể ủng hộ bằng cách chuyển khoản tới tài khoản bên dưới hoặc đơn giản là chia sẻ, giới thiệu {{AppName}} cho nhiều người sử dụng."
        ),
        Draft(table: .support, key: "support.donate.accountTitle", vi: "Thông tin tài khoản"),
        Draft(table: .support, key: "support.donate.shareTitle", vi: "Nội dung chia sẻ"),
        Draft(
            table: .support, key: "support.donate.shareText", arguments: [appTM, "https://{{app-slug}}.kal.vn"],
            vi:
                "Giới thiệu với mọi người {{AppNameTM}}, một bộ gõ tiếng Việt miễn phí nhưng rất ngon nè! Tải ở đây: https://{{app-slug}}.kal.vn"
        ),
        Draft(table: .support, key: "support.donate.share", vi: "Chia sẻ..."),
        // Support pane sections and Licences (Pa, 15/11/2026; "gởi" as Pa wrote it).
        Draft(
            table: .support, key: "support.diagnostics.explanation",
            vi: "Xem tình trạng bộ gõ, hoặc ghi lại thao tác gõ trong thời gian ngắn để gởi kèm báo lỗi."),
        Draft(
            table: .support, key: "support.settings.explanation",
            vi:
                "Lưu cài đặt và dễ dàng nhập lại ở máy khác mà không cần cấu hình lại, hoặc đưa tất cả về mặc định."),
        Draft(
            table: .support, key: "support.privacy.body", arguments: [appTM],
            vi:
                "{{AppNameTM}} chỉ lưu thông tin ở máy hiện hành và không lưu nội dung bạn viết cũng như không tự ý gởi về server các hoạt động mà không có sự đồng ý của người dùng. Kết nối mạng duy nhất là kiểm tra cập nhật."
        ),
        Draft(
            table: .support, key: "support.licences.copyright", arguments: [app],
            vi: "Bản quyền © 2026 các tác giả {{AppName}}"),
        Draft(table: .menu, key: "menu.donate", arguments: [app], vi: "Ủng hộ {{AppName}}..."),
    ]

    static let onboarding: [Draft] = [
        Draft(
            table: .onboarding, key: "onboarding.welcome.title", arguments: [app],
            vi: "Chào mừng bạn đến với {{AppName}}"),
        Draft(
            table: .onboarding, key: "onboarding.welcome.body",
            vi: "Bộ gõ tiếng Việt cho Mac. Cài đặt chỉ mất khoảng một phút, sau đó bạn cứ gõ như bình thường."),
        Draft(
            table: .onboarding, key: "onboarding.welcome.footnote", arguments: [app],
            vi: "{{AppName}} không gửi nội dung bạn gõ đi đâu cả và không lưu lại những gì bạn gõ."),
        Draft(table: .onboarding, key: "onboarding.welcome.start", vi: "Bắt đầu"),
        Draft(
            table: .onboarding, key: "onboarding.permission.title", arguments: [app],
            vi: "Cho phép {{AppName}} nhận phím gõ"),
        Draft(
            table: .onboarding, key: "onboarding.permission.body", arguments: [app, "Quyền riêng tư & Bảo mật"],
            vi: "Để thêm dấu khi bạn gõ, macOS cần bạn cho phép {{AppName}} trong mục Quyền riêng tư & Bảo mật."),
        Draft(
            table: .onboarding, key: "onboarding.permission.bullet.keysOnly", arguments: [app],
            vi: "{{AppName}} chỉ xử lý phím khi bạn gõ chữ."),
        Draft(table: .onboarding, key: "onboarding.permission.bullet.passwords", vi: "Ô mật khẩu luôn được bỏ qua."),
        Draft(
            table: .onboarding, key: "onboarding.permission.bullet.local",
            vi: "Không có dữ liệu nào rời khỏi máy của bạn."),
        Draft(
            table: .onboarding, key: "onboarding.permission.instruction",
            arguments: [
                "Cài đặt hệ thống", "Quyền riêng tư & Bảo mật", "Điều khiển thiết bị và truy cập dữ liệu", app,
            ],
            vi:
                "Mở Cài đặt hệ thống > Quyền riêng tư & Bảo mật > Điều khiển thiết bị và truy cập dữ liệu, rồi bật {{AppName}}."
        ),
        Draft(
            table: .onboarding, key: "onboarding.permission.openPane",
            arguments: ["Điều khiển thiết bị và truy cập dữ liệu"], vi: "Mở Điều khiển thiết bị và truy cập dữ liệu"),
        Draft(table: .onboarding, key: "onboarding.permission.granted", vi: "Đã cấp quyền"),
        // Screen 2 rows and the Input Monitoring line (Pa, 2026-11-14, feedback item 1).
        Draft(table: .onboarding, key: "onboarding.permission.row.granted", vi: "Đã bật"),
        Draft(table: .onboarding, key: "onboarding.permission.row.needed", vi: "Cần bật"),
        Draft(
            table: .onboarding, key: "onboarding.permission.inputMonitoring", arguments: ["Giám sát đầu vào", app],
            vi:
                "macOS cần thêm quyền Giám sát đầu vào để {{AppName}} nhận phím gõ. Nếu công tắc đã bật mà dòng này vẫn báo cần bật, hãy mở lại {{AppName}}."
        ),
        Draft(table: .onboarding, key: "onboarding.permission.relaunch", arguments: [app], vi: "Mở lại {{AppName}}"),
        Draft(
            table: .onboarding, key: "onboarding.permission.helpLink", arguments: [app],
            vi: "Không thấy {{AppName}} trong danh sách?"),
        Draft(table: .onboarding, key: "onboarding.permissionHelp.reset", vi: "Đặt lại quyền"),
        Draft(
            table: .onboarding, key: "onboarding.permission.lost", arguments: [app],
            vi: "macOS đã tắt quyền của {{AppName}}, thường sau khi cập nhật hệ điều hành. Bật lại là gõ được ngay."),
        Draft(table: .onboarding, key: "onboarding.method.title", vi: "Bạn gõ kiểu nào?"),
        Draft(table: .onboarding, key: "onboarding.method.telex.title", vi: "Telex"),
        Draft(table: .onboarding, key: "onboarding.method.telex.example", vi: "tieengs Vieetj -> tiếng Việt"),
        Draft(table: .onboarding, key: "onboarding.method.vni.title", vi: "VNI"),
        Draft(table: .onboarding, key: "onboarding.method.vni.example", vi: "tie61ng Vie65t -> tiếng Việt"),
        Draft(table: .common, key: "common.continue", vi: "Tiếp tục"),
        Draft(table: .common, key: "common.back", vi: "Quay lại"),
        Draft(table: .common, key: "common.skip", vi: "Bỏ qua"),
        Draft(table: .onboarding, key: "onboarding.switching.title", vi: "Chuyển Việt / Anh"),
        Draft(
            table: .onboarding, key: "onboarding.switching.body",
            vi:
                "Nhấn rồi thả Control + Shift để chuyển. Biểu tượng trên thanh menu hiện V khi gõ tiếng Việt, E khi gõ tiếng Anh."
        ),
        Draft(
            table: .onboarding, key: "onboarding.switching.perApp", arguments: [app],
            vi:
                "{{AppName}} nhớ lựa chọn của bạn cho từng ứng dụng. Ví dụ: Terminal luôn tiếng Anh, Zalo luôn tiếng Việt."
        ),
        Draft(
            table: .onboarding, key: "onboarding.switching.englishWords",
            vi: "Từ tiếng Anh như text, user, wifi sẽ tự giữ nguyên, nên phần lớn thời gian bạn không cần chuyển."),
        Draft(table: .onboarding, key: "onboarding.switching.changeKey", vi: "Đổi phím chuyển"),
        Draft(table: .onboarding, key: "onboarding.conflicts.title", vi: "Có bộ gõ khác đang chạy"),
        Draft(
            table: .onboarding, key: "onboarding.conflicts.body", arguments: ["{{OtherApp}}"],
            vi: "Hai bộ gõ cùng lúc sẽ làm lặp hoặc mất chữ. Bạn nên thoát {{OtherApp}} và tắt nó khi đăng nhập."),
        Draft(
            table: .onboarding, key: "onboarding.conflicts.howToQuit", arguments: ["{{OtherApp}}"],
            vi: "Hướng dẫn thoát {{OtherApp}}"),
        Draft(table: .onboarding, key: "onboarding.conflicts.checkAgain", vi: "Kiểm tra lại"),
        Draft(
            table: .onboarding, key: "onboarding.conflicts.builtIn", arguments: [app],
            vi:
                "Bạn có thể giữ hoặc gỡ bộ gõ Tiếng Việt của macOS. Khi dùng {{AppName}}, hãy chọn bàn phím ABC hoặc U.S."
        ),
        Draft(
            table: .onboarding, key: "onboarding.import.title", arguments: ["{{OtherApp}}"],
            vi: "Mang danh sách viết tắt và cài đặt từ {{OtherApp}}"),
        Draft(
            table: .onboarding, key: "onboarding.import.body", arguments: ["{{OtherApp}}"],
            vi: "Bạn có thể chuyển danh sách viết tắt từ {{OtherApp}} sang bằng file văn bản theo mẫu."),
        Draft(table: .onboarding, key: "onboarding.import.chooseFile", vi: "Chọn file..."),
        Draft(table: .onboarding, key: "onboarding.import.later", vi: "Để sau"),
        Draft(table: .onboarding, key: "onboarding.tryIt.title", vi: "Thử gõ một chút"),
        Draft(table: .onboarding, key: "onboarding.tryIt.target.vietnamese", vi: "Tiếng Việt có dấu"),
        Draft(table: .onboarding, key: "onboarding.tryIt.target.english", vi: "text user wifi"),
        // Screen 7 items and their second lines (Pa, 2026-11-14, feedback item 4).
        Draft(
            table: .onboarding, key: "onboarding.tryIt.intro",
            vi: "Gõ vào ô bên dưới. Mỗi mục được đánh dấu khi bạn làm xong."),
        Draft(
            table: .onboarding, key: "onboarding.tryIt.item.vietnamese", arguments: ["Tiếng Việt có dấu"],
            vi: "Gõ cụm từ “Tiếng Việt có dấu”"),
        Draft(
            table: .onboarding, key: "onboarding.tryIt.detail.vietnamese",
            arguments: ["Telex", "Tieengs Vieetj cos daaus"], vi: "Phím cần gõ (Telex): Tieengs Vieetj cos daaus"),
        Draft(table: .onboarding, key: "onboarding.tryIt.sequence.telex", vi: "Tieengs Vieetj cos daaus"),
        Draft(table: .onboarding, key: "onboarding.tryIt.sequence.vni", vi: "Tie61ng Vie65t co1 da61u"),
        Draft(
            table: .onboarding, key: "onboarding.tryIt.item.english", arguments: ["text user wifi"],
            vi: "Gõ các từ tiếng Anh “text user wifi”"),
        Draft(
            table: .onboarding, key: "onboarding.tryIt.detail.english", arguments: ["text user wifi"],
            vi: "Phím cần gõ: text user wifi. Chữ phải giữ nguyên, không bị thêm dấu."),
        Draft(
            table: .onboarding, key: "onboarding.tryIt.item.toggle", arguments: ["{{ToggleKey}}"],
            vi: "Nhấn rồi thả {{ToggleKey}} để chuyển sang tiếng Anh, rồi làm lại một lần nữa để về tiếng Việt"),
        Draft(
            table: .onboarding, key: "onboarding.tryIt.detail.toggle", arguments: ["V", "E"],
            vi: "Biểu tượng trên thanh menu đổi từ V sang E, rồi về lại V."),
        Draft(table: .onboarding, key: "onboarding.tryIt.done", vi: "Xong"),
        Draft(table: .onboarding, key: "onboarding.done.title", vi: "Xong rồi!"),
        Draft(
            table: .onboarding, key: "onboarding.done.body", arguments: [app],
            vi: "{{AppName}} nằm trên thanh menu, góc trên bên phải màn hình."),
        Draft(
            table: .onboarding, key: "onboarding.done.openAtLogin", arguments: [app],
            vi: "Khởi động {{AppName}} cùng hệ thống"),
        // Pa, 2026-11-14 (feedback item 5).
        Draft(table: .onboarding, key: "onboarding.done.start", vi: "Bắt đầu", en: "Start"),
    ]

    static let bugReport: [Draft] = [
        Draft(table: .diagnostics, key: "bugReport.app.label", vi: "Lỗi xảy ra ở ứng dụng nào?"),
        Draft(table: .diagnostics, key: "bugReport.symptom.label", vi: "Chuyện gì xảy ra?"),
        Draft(table: .common, key: "bugReport.symptom.lostLetters", vi: "Mất chữ"),
        Draft(table: .common, key: "bugReport.symptom.duplicatedLetters", vi: "Lặp chữ"),
        Draft(table: .common, key: "bugReport.symptom.wrongTone", vi: "Sai dấu"),
        Draft(table: .common, key: "bugReport.symptom.cannotTypeVietnamese", vi: "Không gõ được tiếng Việt"),
        Draft(table: .common, key: "bugReport.symptom.lag", vi: "Chậm / giật"),
        Draft(table: .common, key: "bugReport.symptom.other", vi: "Khác"),
        Draft(table: .diagnostics, key: "bugReport.description.label", vi: "Bạn gõ gì và mong ra gì?"),
        Draft(
            table: .diagnostics, key: "bugReport.description.hint", arguments: [app],
            vi: "Bạn tự gõ lại ví dụ ở đây. {{AppName}} không tự gửi những gì bạn đã gõ."),
        Draft(table: .diagnostics, key: "bugReport.preview.disclosure", vi: "Xem trước dữ liệu sẽ gửi"),
        Draft(table: .diagnostics, key: "bugReport.github", vi: "Mở GitHub"),
        Draft(table: .diagnostics, key: "bugReport.email", vi: "Gửi qua email"),
        Draft(table: .diagnostics, key: "bugReport.saveFile", vi: "Lưu file..."),
    ]

    static let all: [Draft] = menu + status + settings + onboarding + bugReport

    @Test func everyDraftIsVerbatim() throws {
        let bundle = try TemporaryAppBundle(catalogs: StringTable.allCases)
        let vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        let en = Localizer(language: .english, appBundle: bundle.bundle)
        for draft in Self.all {
            #expect(vi.contains(draft.key, table: draft.table), "\(draft.key) is missing")
            let arguments = draft.arguments.map { $0 as any CVarArg }
            #expect(vi.format(draft.key, table: draft.table, arguments: arguments) == draft.vi, "\(draft.key)")
            if let expected = draft.en {
                #expect(en.format(draft.key, table: draft.table, arguments: arguments) == expected, "\(draft.key)")
            }
        }
    }

    @Test func draftsCoverEveryOnboardingScreenAndTheMenuOrder() {
        // The list itself: eight menu items of PRD-R11 besides the radio pairs, and all eight onboarding screens.
        let keys = Set(Self.all.map(\.key))
        for prefix in ["welcome", "permission", "method", "switching", "conflicts", "import", "tryIt", "done"] {
            #expect(keys.contains { $0.hasPrefix("onboarding.\(prefix).") }, "screen \(prefix)")
        }
        for key in ["menu.macros", "menu.settings", "menu.reportProblem", "menu.checkForUpdates", "menu.donate"] {
            #expect(keys.contains(key))
        }
    }
}
