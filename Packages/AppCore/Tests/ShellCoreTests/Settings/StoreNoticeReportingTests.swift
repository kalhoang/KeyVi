// SPDX-License-Identifier: GPL-3.0-or-later
//
// Store notices outside the Settings window (PLT-R1006, PLT-R1007): each new notice maps to its contracts.md
// `LogEvent.SettingsEvent` and health event, so the log and the report carry the episode (PLT-R1202), and
// settings that are not being saved show a menu status line that opens Settings (PRD-R43).

import AppModel
import Diagnostics
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct StoreNoticeReportingTests {
    let at = Date(timeIntervalSince1970: 1_794_528_000)

    @Test func newNoticesMapToContractLogAndHealthEvents_PLTR1006() {
        let safe = StoreNotice.safeMode(recentCrashes: 3)
        let current: [StoreNotice] = [
            safe, .recoveredFromBackup(.settings, backupDate: at), .corruptFileUsingDefaults(.appModes),
            .newerSchemaReadOnly(.macros, schemaVersion: 4), .writeFailed(.ruleOverrides),
        ]
        let added = StoreNoticeReporting.added(previous: [safe], current: current)
        #expect(added == Array(current.dropFirst()))
        #expect(
            added.map(StoreNoticeReporting.logEvent) == [
                .recoveredFromBackup(file: .settings), .corruptFileQuarantined(file: .appModes),
                .newerSchemaReadOnly(file: .macros, schemaVersion: 4),
                .writeFailed(file: .ruleOverrides, errno: StoreNoticeReporting.unknownErrno),
            ])
        #expect(
            added.map { StoreNoticeReporting.healthEvent($0, at: at)?.kind } == [
                .settingsRecovered, .settingsRecovered, .settingsNewerSchema, nil,
            ])
        #expect(added.map(StoreNoticeReporting.logLevel) == [.notice, .error, .notice, .error])
        // Safe mode is logged and recorded by the launch itself; a notice already seen is not reported again.
        #expect(StoreNoticeReporting.logEvent(safe) == nil)
        #expect(StoreNoticeReporting.healthEvent(safe, at: at) == nil)
        #expect(StoreNoticeReporting.added(previous: current, current: current).isEmpty)
    }

    func line(_ state: HostState = .ready(.vietnamese), notices: [StoreNotice], safeMode: Bool = false)
        -> StatusLine?
    {
        StatusLine.forState(
            state, holderHintKey: nil, appName: "Example", frontmostApp: nil, tapRecentlyReenabled: true,
            safeMode: safeMode, storeNotices: notices)
    }

    @Test func unsavedSettingsShowAStatusLineThatOpensSettings_PLTR1006_PRDR43() throws {
        let corrupt = try #require(line(notices: [.corruptFileUsingDefaults(.appModes)]))
        #expect(corrupt.key == StatusText.settingsCorrupt.rawValue)
        #expect(corrupt.arguments == ["app-modes.json", "Example"])
        #expect(corrupt.action == .openSettings)
        #expect(corrupt.actionLabelKey == StatusText.actionOpenSettings.rawValue)
        let failed = try #require(line(notices: [.writeFailed(.settings)]))
        #expect(failed.key == StatusText.settingsWriteFailed.rawValue)
        #expect(failed.arguments == ["settings.json", "Example"])
        let newer = try #require(line(notices: [.newerSchemaReadOnly(.macros, schemaVersion: 4)]))
        #expect(newer.key == StatusText.settingsNewerSchema.rawValue)
        // A state restored from a backup is saved: the tap notice below it shows instead.
        let recovered = line(notices: [.recoveredFromBackup(.settings, backupDate: at)])
        #expect(recovered?.key == StatusText.tapReenabled.rawValue)
        // Host state and safe mode lines come first.
        #expect(line(.noPermission, notices: [.writeFailed(.settings)])?.key == StatusText.noPermission.rawValue)
        #expect(line(notices: [.writeFailed(.settings)], safeMode: true)?.key == StatusText.safeMode.rawValue)
    }

    @Test func everyStatusLineRendersInBothLanguages() throws {
        let app = try TemporaryAppBundle(catalogs: [.status])
        let notices: [StoreNotice] = [
            .corruptFileUsingDefaults(.appModes), .writeFailed(.settings),
            .newerSchemaReadOnly(.macros, schemaVersion: 4),
        ]
        for language in InterfaceLanguage.allCases {
            let localizer = Localizer(language: language, appBundle: app.bundle)
            for notice in notices {
                let status = try #require(line(notices: [notice]))
                let message = status.message(localizer)
                #expect(message.contains(notice.fileName) && message.contains("Example"))
                #expect(!message.contains("%") && message != status.key)
                let label = try #require(status.actionLabel(localizer))
                #expect(!label.isEmpty && label != status.actionLabelKey)
            }
        }
    }
}

extension StoreNotice {
    fileprivate var fileName: String {
        switch self {
        case .recoveredFromBackup(let file, _), .corruptFileUsingDefaults(let file), .newerSchemaReadOnly(let file, _),
            .writeFailed(let file):
            file.rawValue
        case .safeMode: ""
        }
    }
}
