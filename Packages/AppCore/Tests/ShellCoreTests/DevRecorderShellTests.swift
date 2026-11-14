// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): the dev recorder's status menu entries and copy, and the settings snapshot it writes
// (engine-affecting values and counts, never word lists or macro bodies).

#if DEV_RECORDER
import AppModel
import Diagnostics
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct DevRecorderShellTests {
    @Test func recordingShowsTheStatusMarkerPauseAndFolder() {
        #expect(
            DevRecorderMenuEntry.entries(isStarted: true, pausedUntil: nil) == [
                .status(pausedUntil: nil), .mark, .pause, .openFolder,
            ])
    }

    @Test func pausedOffersResumeInsteadOfPause() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(
            DevRecorderMenuEntry.entries(isStarted: true, pausedUntil: until) == [
                .status(pausedUntil: until), .mark, .resume, .openFolder,
            ])
    }

    @Test func aRecorderThatCouldNotStartStillOpensItsFolder() {
        #expect(DevRecorderMenuEntry.entries(isStarted: false, pausedUntil: nil) == [.openFolder])
    }

    @Test func copyIsTheAgreedTextInBothLanguages() throws {
        let bundle = try TemporaryAppBundle(catalogs: [.devRecorder])
        let vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        let en = Localizer(language: .english, appBundle: bundle.bundle)
        #expect(DevRecorderMenuEntry.status(pausedUntil: nil).title(vi) == "Đang ghi nhật ký gõ (bản dev)")
        #expect(DevRecorderMenuEntry.mark.title(vi) == "Đánh dấu lỗi vừa gặp")
        #expect(DevRecorderMenuEntry.pause.title(vi) == "Tạm dừng ghi 30 phút")
        #expect(DevRecorderMenuEntry.resume.title(vi) == "Tiếp tục ghi")
        #expect(DevRecorderMenuEntry.openFolder.title(vi) == "Mở thư mục nhật ký")
        #expect(DevRecorderMenuEntry.pause.title(en) == "Pause recording for 30 minutes")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let until = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 14, minute: 5)))
        #expect(DevRecorderMenuEntry.status(pausedUntil: until).title(vi) == "Đã tạm dừng ghi đến 14:05")
        #expect(DevRecorderMenuEntry.status(pausedUntil: until).title(en).hasPrefix("Recording paused until 2:05"))
        for entry in DevRecorderMenuEntry.entries(isStarted: true, pausedUntil: nil) {
            #expect(vi.contains(entry.accessibilityHintKey.rawValue, table: .devRecorder))
        }
    }

    @Test func settingsSnapshotHoldsEngineValuesAndOnlyCounts() {
        var user = UserSettings()
        user.typingMethod = .set(.vni)
        user.tonePlacement = .set(.modern)
        user.keepAsTyped = ["sample", "words"]
        let state = SettingsState(
            user: user,
            macros: [
                StoredMacro(id: UUID(), trigger: "ko", expansion: "không", adaptCase: true, enabled: true),
                StoredMacro(id: UUID(), trigger: "dc", expansion: "được", adaptCase: true, enabled: false),
            ])
        let values = DevRecorderSettings.snapshot(state).values
        #expect(values["typingMethod"] == "vni" && values["tonePlacement"] == "modern")
        #expect(values["keepAsTypedCount"] == "2" && values["enabledMacros"] == "1")
        let joined = values.values.joined(separator: " ")
        #expect(!joined.contains("sample") && !joined.contains("không") && !joined.contains("ko"))
    }
}
#endif
