// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R1206: secure-input episodes are health events with the likely holder's bundle ID, and every category the
// requirement lists has its own event kind.

import AppModel
import Foundation
import Testing

@testable import Diagnostics

@Suite struct SecureInputEpisodeTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// The holder's display name is a canary: it must never reach an event (PLT-R901).
    static let canaryName = "zqxkanaryholder"
    static let vault = holder(42, .application, "com.example.Vault")
    static let terminal = holder(43, .application, "com.example.Term")
    static let login = holder(1, .loginWindow, nil)

    static func holder(_ pid: Int32, _ kind: SecureInputHolder.Kind, _ bundle: String?) -> SecureInputHolder {
        SecureInputHolder(
            pid: pid, kind: kind, bundle: bundle.flatMap(BundleKey.init(rawValue:)), displayName: canaryName,
            hintKey: nil)
    }

    func episodes(_ log: HealthEventLog) -> [HealthEvent] {
        log.recent(limit: 50).filter { $0.kind == .secureInputEpisode }
    }

    @Test func anEpisodeIsRecordedWhenItEndsWithHolderAndDuration() {
        let log = HealthEventLog()
        log.noteSecureInput(Self.vault, active: true, at: Self.start)
        log.noteSecureInput(Self.vault, active: true, at: Self.start.addingTimeInterval(1))  // still the same
        #expect(episodes(log).isEmpty)
        log.noteSecureInput(nil, active: false, at: Self.start.addingTimeInterval(2.5))
        #expect(
            episodes(log) == [
                HealthEvent(
                    kind: .secureInputEpisode, at: Self.start.addingTimeInterval(2.5),
                    detail: .secureInput(
                        holder: Self.vault.bundle, holderKind: .application, durationMilliseconds: 2_500))
            ])
        log.noteSecureInput(nil, active: false, at: Self.start.addingTimeInterval(3))
        #expect(episodes(log).count == 1, "no episode without a start")
        let rendered = episodes(log).map { $0.summaryLine + LogEvent.health($0).rendered.fields.description }
        #expect(rendered.allSatisfy { !$0.contains(Self.canaryName) })
    }

    @Test func aNewHolderEndsTheEpisodeOfThePreviousOne() {
        let log = HealthEventLog()
        log.noteSecureInput(Self.vault, active: true, at: Self.start)
        log.noteSecureInput(Self.terminal, active: true, at: Self.start.addingTimeInterval(1))
        log.noteSecureInput(Self.login, active: true, at: Self.start.addingTimeInterval(3))
        log.noteSecureInput(nil, active: true, at: Self.start.addingTimeInterval(4))  // holder unknown
        log.noteSecureInput(nil, active: false, at: Self.start.addingTimeInterval(6))
        let details = episodes(log).map(\.detail)
        #expect(
            details == [
                .secureInput(holder: Self.vault.bundle, holderKind: .application, durationMilliseconds: 1_000),
                .secureInput(holder: Self.terminal.bundle, holderKind: .application, durationMilliseconds: 2_000),
                .secureInput(holder: nil, holderKind: .loginWindow, durationMilliseconds: 1_000),
                .secureInput(holder: nil, holderKind: nil, durationMilliseconds: 2_000),
            ])
    }

    @Test func aClockSetBackNeverGivesANegativeDuration() {
        let log = HealthEventLog()
        log.noteSecureInput(Self.vault, active: true, at: Self.start)
        log.noteSecureInput(nil, active: false, at: Self.start.addingTimeInterval(-30))
        #expect(
            episodes(log).map(\.detail) == [
                .secureInput(holder: Self.vault.bundle, holderKind: .application, durationMilliseconds: 0)
            ])
    }

    @Test func everyPLTR1206CategoryHasAnEventKind() {
        let required: [HealthEvent.Kind] = [
            .tapTimeout, .watchdogTrip, .flush, .fallbackActivated, .axCircuitBreakerTrip, .echoLoss,
            .permissionTransition, .secureInputEpisode, .ruleLoadError, .placeholderResidue,
        ]
        #expect(Set(required).isSubset(of: Set(HealthEvent.Kind.allCases)))
    }
}
