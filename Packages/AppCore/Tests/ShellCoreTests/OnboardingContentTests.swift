// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R40 screen copy (verbatim), PRD-R64 pane names in the macOS language, PLT-R702/R712 Input Monitoring,
// PLT-R740/R741 re-grant guidance, PLT-R710 move offer, try-it checklist.

import AppModel
import Foundation
import InputHost
import Testing

@testable import ShellCore

@Suite struct TryItChecklistTests {
    func checklist(_ mode: TypingMode = .vietnamese) -> TryItChecklist {
        TryItChecklist(vietnameseTarget: "Tiếng Việt có dấu", englishTarget: "text user wifi", startMode: mode)
    }

    @Test func itemsTickWhenDone() {
        var list = checklist()
        list.textChanged("tiếng việt có dấu")
        #expect(list.completed == [.typeVietnamese])
        list.textChanged("Tiếng Việt có dấu text user wifi")
        #expect(list.completed == [.typeVietnamese, .typeEnglishWords])
        list.modeChanged(to: .english)
        #expect(!list.isComplete)
        list.modeChanged(to: .vietnamese)
        #expect(list.isComplete)
    }

    @Test func decomposedInputCountsAndMissingMarksDoNot() {
        var list = checklist()
        list.textChanged("Tie\u{0302}\u{0301}ng Vie\u{0323}\u{0302}t co\u{0301} da\u{0302}\u{0301}u")
        #expect(list.completed.contains(.typeVietnamese))
        var plain = checklist()
        plain.textChanged("Tieng Viet co dau")
        #expect(plain.completed.isEmpty)
        // English restore failed: the words came out with marks.
        plain.textChanged("tẽt user wifi")
        #expect(plain.completed.isEmpty)
    }

    @Test func toggleMustLeaveAndComeBack() {
        var list = checklist(.english)
        list.modeChanged(to: .english)
        #expect(list.completed.isEmpty)
        list.modeChanged(to: .vietnamese)
        #expect(list.completed.isEmpty)
        list.modeChanged(to: .english)
        #expect(list.completed == [.toggleAndBack])
        #expect(TryItChecklist.labelKey(.toggleAndBack) == .tryItItemToggle)
        #expect(TryItChecklist.labelKey(.typeVietnamese) == .tryItItemVietnamese)
        #expect(TryItChecklist.labelKey(.typeEnglishWords) == .tryItItemEnglish)
    }
}

@Suite struct OnboardingContentTests {
    let bundle: TemporaryAppBundle
    let vi: Localizer
    let en: Localizer
    let viPanes27: SystemPaneNames
    let enPanes26: SystemPaneNames

    init() throws {
        bundle = try TemporaryAppBundle(catalogs: [.onboarding])
        vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        en = Localizer(language: .english, appBundle: bundle.bundle)
        let table = try SystemPaneTableTests.shipped()
        viPanes27 = table.names(macOS: LooseVersion("27.1")!, systemLanguage: "vi-VN")
        enPanes26 = table.names(macOS: LooseVersion("26.1")!, systemLanguage: "en-US")
    }

    @Test func permissionScreenIsVerbatimWithPaneNamesFromTheTable() {
        let content = PermissionScreenContent(
            localizer: vi, appName: "Example", panes: viPanes27, status: Permissions.missing, permissionLost: false)
        #expect(content.title == "Cho phép Example nhận phím gõ")
        #expect(
            content.body == "Để thêm dấu khi bạn gõ, macOS cần bạn cho phép Example trong mục Quyền riêng tư & Bảo mật."
        )
        #expect(
            content.bullets == [
                "Example chỉ xử lý phím khi bạn gõ chữ.", "Ô mật khẩu luôn được bỏ qua.",
                "Không có dữ liệu nào rời khỏi máy của bạn.",
            ])
        #expect(
            content.instruction
                == "Mở Cài đặt hệ thống > Quyền riêng tư & Bảo mật > Điều khiển thiết bị và truy cập dữ liệu, rồi bật Example."
        )
        #expect(content.openPaneButton == "Mở Cài đặt hệ thống")
        #expect(content.lostNotice == nil && content.staleNotice == nil && content.inputMonitoringNotice == nil)
        #expect(content.relaunchButton == nil)
    }

    @Test func englishInterfaceOnAnEnglishSystemBeforeMacOS27() {
        let content = PermissionScreenContent(
            localizer: en, appName: "Example", panes: enPanes26, status: Permissions.missing, permissionLost: false)
        #expect(
            content.instruction == "Open System Settings > Privacy & Security > Accessibility, then turn on Example.")
    }

    @Test func englishInterfaceKeepsVietnamesePaneNamesOnAVietnameseSystem() {
        // PRD-R64: pane names follow the macOS language, copy follows the interface language.
        let content = PermissionScreenContent(
            localizer: en, appName: "Example", panes: viPanes27, status: Permissions.missing, permissionLost: false)
        #expect(content.openPaneButton == "Open Cài đặt hệ thống")
    }

    @Test func variantsAddLostStaleAndInputMonitoringNotices() {
        let lost = PermissionScreenContent(
            localizer: vi, appName: "Example", panes: viPanes27, status: Permissions.stale, permissionLost: true)
        #expect(
            lost.lostNotice
                == "macOS đã tắt quyền của Example, thường sau khi cập nhật hệ điều hành. Bật lại là gõ được ngay.")
        #expect(lost.staleNotice?.contains("Đặt lại quyền") == true)  // PLT-R740
        let monitoring = PermissionScreenContent(
            localizer: vi, appName: "Example", panes: viPanes27, status: Permissions.needsInputMonitoring,
            permissionLost: false)
        #expect(monitoring.inputMonitoringNotice?.contains("Giám sát đầu vào") == true)
        #expect(monitoring.openInputMonitoringButton == "Mở Giám sát đầu vào")
        #expect(monitoring.relaunchButton == "Mở lại Example")  // PLT-R712
    }

    @Test func helpSheetResetsOnlyThisAppAndNeverSuggestsSudo() {
        let help = PermissionHelpContent(localizer: vi, appName: "Example", panes: viPanes27)
        #expect(help.steps.count == 3)
        #expect(
            help.steps[0] == "Mở Cài đặt hệ thống > Quyền riêng tư & Bảo mật > Điều khiển thiết bị và truy cập dữ liệu."
        )
        #expect(help.resetButton == "Đặt lại quyền")
        let all = [help.title, help.resetIntro, help.confirmTitle, help.confirmBody, help.fallback] + help.steps
        for text in all {
            #expect(!text.lowercased().contains("sudo"))  // PLT-R741
            #expect(!text.contains("%"))
        }
        #expect(help.fallback.contains("Tiếng Việt"))  // PLT-R206
    }

    /// PLT-R740, PRD-R43: a failed reset is said with the next step (remove and add again), never silently.
    @Test func aFailedPermissionResetIsExplained_PLTR740() {
        struct Failing: PermissionResetting {
            func resetAccessibility(bundleIdentifier: String) throws {
                throw PermissionResetError.commandFailed(status: 1)
            }
        }
        struct Succeeding: PermissionResetting {
            func resetAccessibility(bundleIdentifier: String) throws {}
        }
        #expect(PermissionReset.run(Failing(), bundleIdentifier: "com.example.app") == .failed)
        #expect(PermissionReset.run(Succeeding(), bundleIdentifier: "com.example.app") == .reset)
        let help = PermissionHelpContent(localizer: vi, appName: "Example", panes: viPanes27)
        #expect(help.resetFailed.contains("Example") && !help.resetFailed.contains("%"))
        #expect(!help.resetFailed.lowercased().contains("sudo"))  // PLT-R741
        let english = PermissionHelpContent(localizer: en, appName: "Example", panes: viPanes27)
        #expect(english.resetFailed != help.resetFailed && english.resetFailed.contains("Example"))
    }

    @Test func moveOfferExplainsEachReason() {
        let reasons: [AppLocationCheck.Reason] = [.translocated, .readOnlyVolume, .outsideApplications]
        let bodies = reasons.map { MoveOfferContent(localizer: vi, appName: "Example", reason: $0).body }
        #expect(Set(bodies).count == 3)
        for body in bodies { #expect(body.contains("Example") && !body.contains("%")) }
        let offer = MoveOfferContent(localizer: en, appName: "Example", reason: .readOnlyVolume)
        #expect(offer.title == "Move Example to the Applications folder?")
        #expect(offer.confirm == "Move and reopen")
    }

    @Test func screenCopyIsVerbatimFromPRDR40() {
        #expect(vi.format(OnboardingText.welcomeTitle, "Example") == "Chào mừng bạn đến với Example")
        #expect(
            vi.string(OnboardingText.welcomeBody)
                == "Bộ gõ tiếng Việt cho Mac. Cài đặt chỉ mất khoảng một phút, sau đó bạn cứ gõ như bình thường.")
        #expect(
            vi.format(OnboardingText.welcomeFootnote, "Example")
                == "Example không gửi nội dung bạn gõ đi đâu cả và không lưu lại những gì bạn gõ.")
        #expect(vi.string(OnboardingText.methodTitle) == "Bạn gõ kiểu nào?")
        #expect(vi.string(OnboardingText.switchingTitle) == "Chuyển Việt / Anh")
        #expect(vi.string(OnboardingText.conflictsTitle) == "Có bộ gõ khác đang chạy")
        #expect(vi.format(OnboardingText.importTitle, "Other") == "Mang gõ tắt và cài đặt từ Other")
        #expect(vi.string(OnboardingText.tryItTitle) == "Thử gõ một chút")
        #expect(vi.string(OnboardingText.doneTitle) == "Xong rồi!")
        #expect(vi.format(OnboardingText.doneOpenAtLogin, "Example") == "Mở Example khi đăng nhập")
        #expect(vi.string(OnboardingText.doneStart) == "Bắt đầu gõ")
        #expect(vi.format(OnboardingText.permissionHelpLink, "Example") == "Không thấy Example trong danh sách?")
    }
}
