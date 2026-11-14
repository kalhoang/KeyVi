// SPDX-License-Identifier: GPL-3.0-or-later
//
// The engine identity of dev traces (PLT-R904A, ADR 0007 decision 13).

import Testing

@testable import Diagnostics
@testable import TestSupport
@testable import TraceScanCore

/// ADR 0007 decision 13: the recorder and the scanner compute one engine identity for one engine, and any change of
/// the probes' output changes it.
@Suite struct EngineIdentityTests {
    @Test func theScannerAndTheAppAgreeOnTheEngineIdentity() throws {
        let scanner = try ReplayEngineFactory.bundled().identity
        #expect(scanner == EngineIdentityProbe.appIdentity())
        let probes = DevEngineIdentity.telexProbes.count + DevEngineIdentity.vniProbes.count
        #expect(scanner.hasPrefix("p" + String(probes) + "-") && scanner.count == String(probes).count + 18)
    }

    @Test func anotherBehaviourGivesAnotherIdentity() {
        let echo = DevEngineIdentity.digest { _ in { _ in .passThrough } }
        let doubling = DevEngineIdentity.digest { _ in
            { _ in .edit(deleteCount: 0, insert: "x", thenPassThrough: true) }
        }
        #expect(echo != doubling)
        #expect(DevEngineIdentity.type("ab", with: { _ in .passThrough }) == "ab")
        #expect(
            DevEngineIdentity.type(
                "aa", with: { $0 == "a" ? .edit(deleteCount: 1, insert: "â", thenPassThrough: false) : .passThrough })
                == "â")
    }
}
