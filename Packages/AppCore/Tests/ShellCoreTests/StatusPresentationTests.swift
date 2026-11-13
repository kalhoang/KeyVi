// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R10, PLT-R211, PLT-R905: state-to-icon table over every HostState.

import AppModel
import Foundation
import Testing

@testable import ShellCore

/// Every `HostState` the host can publish, with a representative associated value per case.
enum AllHostStates {
    static let rule = RuleID(rawValue: "user.ignore.1")!
    static let holder = SecureInputHolder(
        pid: 42, kind: .application, bundle: BundleKey(rawValue: "com.example.Vault"), displayName: "Vault",
        hintKey: nil)
    static let pauseReasons: [PauseReason] = [
        .secureInput(holder), .secureInput(nil), .nonLatinInputSource(name: "Kotoeri"), .builtInVietnameseSource,
        .passThroughRule(rule), .secureField, .sessionInactive, .userDisabled, .noTextFocus,
    ]
    static let failOpenReasons: [FailOpenReason] = [
        .permissionRevoked, .postingBroken, .tapUnavailable, .watchdog, .callbackStuck,
    ]
    static let all: [HostState] =
        [.noPermission, .starting, .ready(.vietnamese), .ready(.english)] + pauseReasons.map { .paused($0) }
        + failOpenReasons.map { .failOpen($0) }
}

@Suite struct StatusIconTests {
    @Test func iconTableCoversEveryHostState() {
        let expected: [HostState: StatusIconState] = [
            .noPermission: .notWorking,
            .starting: .paused,
            .ready(.vietnamese): .vietnamese,
            .ready(.english): .english,
            .paused(.secureInput(AllHostStates.holder)): .secureInputEnglish,
            .paused(.secureInput(nil)): .secureInputEnglish,
            .paused(.nonLatinInputSource(name: "Kotoeri")): .paused,
            .paused(.builtInVietnameseSource): .paused,
            .paused(.passThroughRule(AllHostStates.rule)): .ignoredApp,
            .paused(.secureField): .secureInputEnglish,
            .paused(.sessionInactive): .paused,
            .paused(.userDisabled): .paused,
            .paused(.noTextFocus): .paused,
            .failOpen(.permissionRevoked): .notWorking,
            .failOpen(.postingBroken): .notWorking,
            .failOpen(.tapUnavailable): .notWorking,
            .failOpen(.watchdog): .notWorking,
            .failOpen(.callbackStuck): .notWorking,
        ]
        #expect(Set(expected.keys) == Set(AllHostStates.all))
        for state in AllHostStates.all {
            let icon = StatusPresentation.iconState(state: state, mode: .english, ignored: false, capturing: false)
            #expect(icon == expected[state], "\(state)")
        }
    }

    @Test func lockBadgeFollowsTheMode() {
        let state = HostState.paused(.secureInput(nil))
        #expect(
            StatusPresentation.iconState(state: state, mode: .vietnamese, ignored: false, capturing: false)
                == .secureInputVietnamese)
        #expect(
            StatusPresentation.iconState(state: state, mode: .english, ignored: false, capturing: false)
                == .secureInputEnglish)
    }

    @Test func ignoredAppShowsTheDotOnlyWhileReady() {
        #expect(
            StatusPresentation.iconState(state: .ready(.vietnamese), mode: .vietnamese, ignored: true, capturing: false)
                == .ignoredApp)
        #expect(
            StatusPresentation.iconState(state: .noPermission, mode: .vietnamese, ignored: true, capturing: false)
                == .notWorking)
    }

    @Test func capturingWinsOverEveryStateForTheWholeRecording() {
        // PLT-R905: changed menu-bar icon for the whole duration.
        for state in AllHostStates.all {
            #expect(
                StatusPresentation.iconState(state: state, mode: .english, ignored: true, capturing: true) == .capturing
            )
        }
    }

    @Test func accessibilityLabelIsTruthfulAboutThePauseReason() {
        // PLT-R211
        func key(_ state: HostState) -> String {
            let icon = StatusPresentation.iconState(state: state, mode: .vietnamese, ignored: false, capturing: false)
            return StatusPresentation.accessibilityLabelKey(icon: icon, state: state)
        }
        #expect(key(.paused(.nonLatinInputSource(name: "x"))) == MenuText.iconPaused.rawValue)
        #expect(key(.paused(.builtInVietnameseSource)) == MenuText.iconPaused.rawValue)
        #expect(key(.starting) == MenuText.iconStarting.rawValue)
        #expect(key(.paused(.noTextFocus)) == MenuText.iconPausedNoTextFocus.rawValue)
        #expect(key(.paused(.userDisabled)) == MenuText.iconPausedOther.rawValue)
        #expect(key(.paused(.sessionInactive)) == MenuText.iconPausedOther.rawValue)
        #expect(key(.noPermission) == MenuText.iconNotWorking.rawValue)
        #expect(key(.failOpen(.permissionRevoked)) == MenuText.iconNotWorking.rawValue)
        #expect(key(.failOpen(.watchdog)) == MenuText.iconNotWorkingFailOpen.rawValue)
        #expect(key(.ready(.vietnamese)) == MenuText.iconVietnamese.rawValue)
        #expect(key(.paused(.secureField)) == MenuText.iconSecureInputVietnamese.rawValue)
    }

    @Test func templateImageNamesAreUniqueAndMatchTheAssetCatalog() throws {
        let names = StatusIconState.allCases.map(\.templateImageName)
        #expect(Set(names).count == names.count)
        for name in names {
            let set = RepoPaths.url("App/Resources/Assets.xcassets/\(name).imageset/Contents.json")
            let data = try Data(contentsOf: set)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let properties = try #require(json["properties"] as? [String: Any])
            #expect(properties["template-rendering-intent"] as? String == "template", "\(name) must be a template")
        }
    }
}
