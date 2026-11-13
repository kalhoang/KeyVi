// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R398C (decision Q38, docs/decisions/0005-pa-decisions-2026-11-13.md): one iTerm2 sentence based on
// iTerm2's public documentation. It names the menu item and the pending password prompt and quotes no setting,
// because the documentation names no on/off setting for the automatic secure keyboard entry.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct SecureInputHintCopyTests {
    static let iTermVietnamese =
        "iTerm2 đang bật Nhập bàn phím an toàn. Hãy tắt mục iTerm2 > Secure Keyboard Entry, hoặc nhập xong (hay hủy) "
        + "lời nhắc mật khẩu đang chờ."
    static let iTermEnglish =
        "iTerm2 has Secure Keyboard Entry turned on. Turn off iTerm2 > Secure Keyboard Entry, or finish or cancel the "
        + "password prompt it is waiting for."

    @Test func iTermCopyIsTheDecidedSentence_PLTR398C() throws {
        let entry = try #require(try Catalog(table: .status).entries[StatusText.hintITerm2.rawValue])
        #expect(entry.values["vi"] == Self.iTermVietnamese)
        #expect(entry.values["en"] == Self.iTermEnglish)
    }

    @Test func iTermCopyQuotesNoSetting_PLTR398C() throws {
        let entry = try #require(try Catalog(table: .status).entries[StatusText.hintITerm2.rawValue])
        let vi = try #require(entry.values["vi"]).lowercased()
        let en = try #require(entry.values["en"]).lowercased()
        #expect(!vi.contains("cài đặt") && !vi.contains("tùy chọn"))
        #expect(!en.contains("setting") && !en.contains("option"))
        #expect(vi.contains("iterm2 > secure keyboard entry") && en.contains("iterm2 > secure keyboard entry"))
    }

    @Test func iTermHolderShowsTheSentenceInTheStatusLine() throws {
        // The compat rule's hint key reaches the copy through the status line (PLT-R397 data-driven hints).
        let app = try TemporaryAppBundle(catalogs: [.status])
        let holder = SecureInputHolder(
            pid: 12, kind: .application, bundle: BundleKey(rawValue: "com.example.Terminal"), displayName: "iTerm2",
            hintKey: "iterm2.secureKeyboardEntry")
        let line = try #require(
            StatusLine.forState(
                .paused(.secureInput(holder)), holderHintKey: nil, appName: "Example", frontmostApp: nil,
                tapRecentlyReenabled: false, onboardingCompleted: true, safeMode: false))
        #expect(line.hint(Localizer(language: .vietnamese, appBundle: app.bundle)) == Self.iTermVietnamese)
        #expect(line.hint(Localizer(language: .english, appBundle: app.bundle)) == Self.iTermEnglish)
    }
}
