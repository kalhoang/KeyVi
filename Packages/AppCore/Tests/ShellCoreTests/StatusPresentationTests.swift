// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R10, PLT-R211, PLT-R905: state-to-icon table over every HostState.

import AppModel
import Diagnostics
import Foundation
import TestSupport
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
        .passThroughRule(rule), .secureField, .sessionInactive, .userDisabled, .noTextFocus, .diagnosticsTest,
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
            .paused(.diagnosticsTest): .paused,
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
        #expect(key(.paused(.userDisabled)) == MenuText.iconPausedUserDisabled.rawValue)
        #expect(key(.paused(.sessionInactive)) == MenuText.iconPausedSessionInactive.rawValue)
        #expect(key(.paused(.diagnosticsTest)) == MenuText.iconPausedDiagnosticsTest.rawValue)
        #expect(key(.noPermission) == MenuText.iconNotWorking.rawValue)
        #expect(key(.failOpen(.permissionRevoked)) == MenuText.iconNotWorking.rawValue)
        #expect(key(.failOpen(.watchdog)) == MenuText.iconNotWorkingFailOpen.rawValue)
        #expect(key(.ready(.vietnamese)) == MenuText.iconVietnamese.rawValue)
        #expect(key(.paused(.secureField)) == MenuText.iconSecureInputVietnamese.rawValue)
    }

    /// Pa's KV mark (S7): one image set per state with light, dark and high-contrast variants, not a template so
    /// the emerald dot keeps its colour; AppKit picks the variant from the status button's effective appearance.
    @Test func everyStateHasAnImageSetWithLightDarkAndHighContrastVariants_PRDR10() throws {
        let names = StatusIconState.allCases.map(\.imageName)
        #expect(Set(names).count == names.count)
        for name in names {
            let folder = RepoPaths.url("App/Resources/Assets.xcassets/\(name).imageset")
            let data = try Data(contentsOf: folder.appendingPathComponent("Contents.json"))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let properties = try #require(json["properties"] as? [String: Any])
            #expect(properties["template-rendering-intent"] as? String == "original", "\(name) keeps its colours")
            #expect(properties["preserves-vector-representation"] as? Bool == true, "\(name) stays vector")
            var appearances: Set<String> = []
            for image in try #require(json["images"] as? [[String: Any]]) {
                let file = try #require(image["filename"] as? String)
                #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), "\(file)")
                let pairs = (image["appearances"] as? [[String: String]] ?? []).map {
                    "\($0["appearance"] ?? "")=\($0["value"] ?? "")"
                }
                appearances.insert(pairs.sorted().joined(separator: ","))
            }
            let expected: Set<String> = ["", "luminosity=dark", "contrast=high", "contrast=high,luminosity=dark"]
            #expect(appearances == expected, "\(name)")
        }
    }
}

/// PLT-R905: the changed icon stays for the whole trace session, also while secure input pauses the recording.
@Suite struct CaptureIconTests {
    @Test func iconStaysCapturingAcrossASecureInputGap_PLTR905() throws {
        let wallClock = FixedWallClock(Date(timeIntervalSince1970: 1_794_528_000))
        let clock = ManualClock()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/captures"),
            fileSystem: InMemoryFileSystem(now: { wallClock.now() }), wallClock: wallClock, clock: clock,
            scheduler: ManualScheduler(clock: clock))
        #expect(!StatusPresentation.isCapturing(capture, now: wallClock.now()))
        _ = try capture.start(duration: .seconds(60))
        capture.beginGap(.secureField)
        #expect(!capture.isRecording)  // the tap records nothing during the gap
        let capturing = StatusPresentation.isCapturing(capture, now: wallClock.now())
        #expect(capturing)
        let icon = StatusPresentation.iconState(
            state: .paused(.secureField), mode: .vietnamese, ignored: false, capturing: capturing)
        #expect(icon == .capturing)
        capture.endGap()
        #expect(StatusPresentation.isCapturing(capture, now: wallClock.now()))
        _ = capture.stop()
        #expect(!StatusPresentation.isCapturing(capture, now: wallClock.now()))
    }
}
