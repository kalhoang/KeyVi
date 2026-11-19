// SPDX-License-Identifier: GPL-3.0-or-later
//
// The engine identity of dev traces (PLT-R904A, ADR 0007 decision 13).

import Testing
import VietnameseEngine

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

    /// ENG-R1119, plan Task 24: the probes include worked examples of 13.12 that the typo correction decides (S01,
    /// S02, the closer of S25 and the one-key Vietnamese case S75), so a build whose correction differs gets
    /// another identity; the recorder and the scanner both digest with the switch on.
    @Test func theProbesExerciseTheTypoCorrection() {
        for probe in ["androdi ", "gramar ", "androdi. ", "ddi pahir "] {
            #expect(DevEngineIdentity.telexProbes.contains(probe))
        }
    }

    /// With the bundled correction data (engine track E1) and the correction itself (E2), the identity with the switch
    /// on differs from the identity with it off, so the probes above reach the correction. Integration enables it once
    /// both are merged into integration/1.1.0 (plan Task 35); until then the engine never corrects.
    @Test(.disabled("needs the bundled correction data and the correction of the engine tracks"))
    func theIdentityFollowsTheCorrection() throws {
        let resources = try ReplayEngineFactory.bundledResources()
        func identity(_ typoCorrection: Bool) -> String {
            DevEngineIdentity.digest { vni in
                let method: InputMethod = vni ? .vni : .telex(TelexOptions())
                let configuration = EngineConfiguration(inputMethod: method, typoCorrection: typoCorrection)
                var session = Session(engine: Engine(configuration: configuration, resources: resources))
                return { character in
                    switch session.handle(.key(KeyInput(character))).action {
                    case .passThrough: .passThrough
                    case .edit(let edit, let thenPassThrough):
                        .edit(deleteCount: edit.deleteCount, insert: edit.insert, thenPassThrough: thenPassThrough)
                    }
                }
            }
        }
        #expect(identity(true) != identity(false))
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
