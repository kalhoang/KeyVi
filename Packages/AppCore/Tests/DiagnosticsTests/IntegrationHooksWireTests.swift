// SPDX-License-Identifier: GPL-3.0-or-later
//
// The integration hooks' wire format (ADR 0502, "Integration hooks"), now one shared definition for the harness
// and the app's INTEGRATION_HOOKS build (W3-A). These tests pin the JSON the W2-E2 harness already writes and
// reads, the command and file-name parsing the app relies on, and the host-state mapping (PLT-R901: codes only).

import AppModel
import Foundation
import Testing

@testable import Diagnostics

private func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

private func sortedJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private let emptyMetrics = MetricsSnapshot(
    callbackDuration: .empty, decideToPosted: .empty, decideToPostedWithAX: .empty, echoRoundTrip: .empty,
    heldWait: .empty, focusRefresh: .empty, flushes: 0, tapTimeouts: 0, fallbackActivations: 0, echoLosses: 0,
    watchdogTrips: 0, lostWhilePostingBroken: 0)

@Suite struct IntegrationHookWireFormatTests {
    /// Requests exactly as FileDropHookChannel writes them (W2-E2), byte for byte with sorted keys.
    @Test func requestJSONIsUnchanged() throws {
        #expect(
            try sortedJSON(AppHookRequest(sequence: 7, command: .state))
                == #"{"command":"state","formatVersion":1,"sequence":7}"#)
        #expect(
            try sortedJSON(AppHookRequest(sequence: 1 << 20, command: .latencyProbe(.burst)))
                == #"{"command":"latencyProbe","formatVersion":1,"profile":"burst","sequence":1048576}"#)
        #expect(
            try sortedJSON(AppHookRequest(sequence: 9, command: .trigger(.revokePermission)))
                == #"{"command":"revokePermission","formatVersion":1,"sequence":9}"#)
    }

    /// A refusal and a full state answer: every field name and value the harness decodes, then a round trip.
    @Test func responseJSONIsPinnedAndRoundTrips() throws {
        let refusal = AppHookResponse.refused(sequence: 12, .busy)
        #expect(try sortedJSON(refusal) == #"{"error":"busy","formatVersion":1,"ok":false,"sequence":12}"#)
        #expect(refusal.errorCode == .busy)

        let state = AppStateSnapshot(
            processIdentifier: 42, state: .paused, mode: nil, pauseReason: .secureInput, failOpenReason: nil,
            secureInputHolderBundleId: bundle("com.example.Terminal"), firstKeyAfterSecureInputReleaseComposed: true,
            tapRecoveries: 2, engineResetsAfterTapRecovery: 2, metrics: emptyMetrics)
        let response = AppHookResponse(sequence: 3, state: state)
        let metricsJSON = try sortedJSON(emptyMetrics)
        let text = try sortedJSON(response).replacingOccurrences(of: metricsJSON, with: "M")
        #expect(
            text == #"{"formatVersion":1,"ok":true,"sequence":3,"state":{"engineResetsAfterTapRecovery":2,"#
                + #""firstKeyAfterSecureInputReleaseComposed":true,"metrics":M,"pauseReason":"secureInput","#
                + #""processIdentifier":42,"secureInputHolderBundleId":"com.example.Terminal","state":"paused","#
                + #""tapRecoveries":2}}"#)
        let decoded = try JSONDecoder().decode(AppHookResponse.self, from: try JSONEncoder().encode(response))
        #expect(decoded == response)

        let probe = LatencyProbeResult(
            ranAt: Date(timeIntervalSince1970: 1_800_000_000),
            results: [
                .init(
                    profile: .normal, decideToPostedP50Microseconds: 400, decideToPostedP99Microseconds: 900,
                    endToEndDeltaP50Microseconds: 2_000, endToEndDeltaP99Microseconds: 4_500, samples: 12)
            ])
        let answer = AppHookResponse(sequence: 4, latencyProbe: probe)
        #expect(try JSONDecoder().decode(AppHookResponse.self, from: try JSONEncoder().encode(answer)) == answer)
        #expect(try sortedJSON(answer).contains(#""latencyProbe":{"ranAt":"#))
    }

    /// The command grammar the app accepts: the W2-E2 names, a profile only for the probe.
    @Test func commandsParseFromTheirWireNames() {
        let commands: [AppHookCommand] = [
            .state, .resetMetrics, .checkForUpdates, .latencyProbe(.fast), .trigger(.tapTimeout),
            .trigger(.revokePermission), .trigger(.restorePermission),
        ]
        for command in commands {
            let request = AppHookRequest(sequence: 1, command: command)
            #expect(AppHookCommand.parse(name: request.command, profile: request.profile) == .success(command))
        }
        #expect(AppHookCommand.parse(name: "latencyProbe", profile: nil) == .failure(.unsupported))
        #expect(AppHookCommand.parse(name: "typeText", profile: nil) == .failure(.unknownCommand))
        #expect(AppHookCommand.parse(name: "", profile: .normal) == .failure(.unknownCommand))
        #expect(AppHookErrorCode.allCases.map(\.rawValue) == ["unknownCommand", "unsupported", "busy"])
        #expect(AppHookResponse(sequence: 1, ok: false, error: "future").errorCode == nil)
    }

    @Test func requestFileNamesCarryTheSequence() {
        #expect(IntegrationHookFiles.requestName(5) == "request-5.json")
        #expect(IntegrationHookFiles.responseName(5) == "response-5.json")
        #expect(IntegrationHookFiles.requestSequence(fileName: "request-1048577.json") == 1_048_577)
        #expect(IntegrationHookFiles.requestSequence(fileName: "request-18446744073709551615.json") == .max)
        for name in [
            "request-.json", "request-1.json.tmp", ".request-1.json.ABC.tmp", "response-1.json", "request--1.json",
            "request-+1.json", "request-18446744073709551616.json", "request-1a.json", "request-1.JSON",
        ] {
            #expect(IntegrationHookFiles.requestSequence(fileName: name) == nil, "\(name)")
        }
        #expect(IntegrationHookFiles.directoryName == "IntegrationHooks")
    }
}

@Suite struct AppStateSnapshotMappingTests {
    private func map(_ state: HostState, firstKey: Bool? = nil) -> AppStateSnapshot {
        AppStateSnapshot(
            processIdentifier: 7, hostState: state, firstKeyAfterSecureInputReleaseComposed: firstKey,
            tapRecoveries: 3, engineResetsAfterTapRecovery: 2, metrics: emptyMetrics)
    }

    @Test func everyHostStateMapsToItsCode() {
        #expect(map(.noPermission).state == .noPermission)
        #expect(map(.starting).state == .starting && map(.starting).mode == nil)
        let ready = map(.ready(.english))
        #expect(ready.state == .ready && ready.mode == .english && ready.pauseReason == nil)
        let failed = map(.failOpen(.permissionRevoked))
        #expect(failed.state == .failOpen && failed.failOpenReason == .permissionRevoked && failed.passesKeysThrough)
        let paused = map(.paused(.userDisabled), firstKey: false)
        #expect(paused.state == .paused && paused.pauseReason == .userDisabled && paused.mode == nil)
        #expect(paused.firstKeyAfterSecureInputReleaseComposed == false && paused.secureInputHolderBundleId == nil)
        #expect(paused.processIdentifier == 7 && paused.tapRecoveries == 3 && paused.engineResetsAfterTapRecovery == 2)
    }

    @Test func secureInputHolderIsItsBundleOnly() {
        let holder = SecureInputHolder(
            pid: 99, kind: .application, bundle: bundle("com.example.Terminal"), displayName: "Terminal",
            hintKey: "terminal.secureKeyboardEntry")
        let snapshot = map(.paused(.secureInput(holder)))
        #expect(snapshot.pauseReason == .secureInput)
        #expect(snapshot.secureInputHolderBundleId == bundle("com.example.Terminal"))
        #expect(map(.paused(.secureInput(nil))).secureInputHolderBundleId == nil)
    }

    /// PLT-R901: names the host state carries for the menu (the input source name, the holder's display name)
    /// never reach the JSON the app writes.
    @Test func responsesCarryNoContent() throws {
        let canary = "CANARYxq7Tz"
        let holder = SecureInputHolder(
            pid: 99, kind: .process, bundle: nil, displayName: canary, hintKey: canary)
        for state in [HostState.paused(.nonLatinInputSource(name: canary)), .paused(.secureInput(holder))] {
            let json = try sortedJSON(AppHookResponse(sequence: 1, state: map(state)))
            #expect(!json.contains(canary))
        }
    }
}
