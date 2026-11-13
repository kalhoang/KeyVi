// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Privacy canary (section 9 acceptance, PLT-R901) and egress check (13.7, PLT-R906): byte patterns, scanner,
// canary list kept equal to what the engine shows, canary scenarios covering every strategy, lsof parsing and the
// egress verdict. Evidence and sampling are fakes; nothing reads the real log or network.

import AppModel
import Foundation
import RealtimeSupport
import Testing
import VietnameseEngine

@testable import TestSupport

@Suite struct PrivacyCanaryTests {
    @Test func patternsCoverEveryEncodingAWriterMightUse() {
        let encodings = Set(PrivacyCanary.patterns(for: "kẩnyzqx").map(\.encoding))
        for encoding in [
            "utf8-nfc", "utf8-nfd", "utf16le-nfc", "utf16be-nfc", "json-escaped-nfc", "utf8-nfc-upper", "utf16be-nfd",
        ] {
            #expect(encodings.contains(encoding), "\(encoding)")
        }
        // ASCII tokens collapse NFC/NFD duplicates.
        #expect(PrivacyCanary.patterns(for: "kanaryzqx").count < PrivacyCanary.patterns(for: "kẩnyzqx").count)
        #expect(PrivacyCanary.jsonEscaped("kẩ") == "k\\u1ea9")
    }

    @Test func scannerFindsCanariesInFilesAndTheLogAndNothingElse() throws {
        let fileSystem = InMemoryFileSystem()
        let directory = URL(fileURLWithPath: "/app")
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
        let files: [(String, Data)] = [
            ("settings.json", Data(#"{"settings":{"typingMethod":"telex"}}"#.utf8)),
            ("log.jsonl", Data(#"{"event":"kẩnyzqx"}"#.utf8)),
            ("prefs.plist", "KANARYZQX".data(using: .utf16BigEndian)!),
            ("nfd.txt", Data("kẩnyzqx".decomposedStringWithCanonicalMapping.utf8)),
        ]
        for (name, data) in files {
            try fileSystem.writeAtomically(
                data, to: directory.appendingPathComponent(name), permissions: .ownerOnlyFile)
        }
        let urls = files.map { directory.appendingPathComponent($0.0) } + [directory.appendingPathComponent("missing")]
        let report = PrivacyScanner().scan(files: urls, fileSystem: fileSystem, log: "typed kanaryzqx here")
        #expect(report.scannedFiles == 4 && report.unreadable == ["/app/missing"] && !report.passed)
        #expect(
            Set(report.findings.map(\.location)) == [
                "/app/log.jsonl", "/app/prefs.plist", "/app/nfd.txt", "unified log",
            ])
        #expect(report.findings.first { $0.location == "/app/prefs.plist" }?.encoding == "utf16be-nfc-upper")
        let clean = PrivacyScanner().scan(files: [urls[0]], fileSystem: fileSystem, log: "nothing")
        #expect(clean.passed && clean.findings.isEmpty && clean.scannedLogBytes == 7)
    }

    /// `PrivacyCanary.canaries` lists the key script and every display the engine shows once the unique tail
    /// (`zqx`) is being typed, plus the committed text: if the engine changes, this test names the new display.
    @Test func canaryTextsAreWhatTheEngineShows() async throws {
        let settings = try await OracleSettings.load(.factory, targets: try repositoryTargets())
        let engine = try ScenarioTextOracle.engine(settings: settings)
        for canary in PrivacyCanary.canaries {
            var session = Session(engine: engine)
            var displays: [String] = []
            let tail = canary.keys.distance(from: canary.keys.startIndex, to: canary.keys.firstIndex(of: "z")!)
            for (index, key) in canary.keys.enumerated() {
                let output = session.handle(.key(KeyInput(key)))
                if index >= tail, !output.composingText.isEmpty, !displays.contains(output.composingText) {
                    displays.append(output.composingText)
                }
            }
            var oracle = try ScenarioTextOracle(settings: settings, focused: "f")
            oracle.type(canary.keys.map(String.init) + ["space"])
            let committed = String(oracle.text.dropLast())
            let expected = [committed] + displays.filter { $0 != committed }
            #expect(canary.texts == expected, "\(canary.keys): \(expected)")
            #expect(canary.texts.allSatisfy { $0.count >= 5 })
        }
        #expect(PrivacyCanary.tokens.first == "kanaryzqx")
    }

    /// Every injection strategy types a canary (profile privacy-canary), and every canary scenario types one.
    @Test func canaryScenariosCoverEveryStrategy() throws {
        let scenarios = try ScenarioRunner.load(directory: repositoryRoot.appendingPathComponent("compat/scenarios"))
            .filter { PrivacyCanary.isCanaryScenario($0.id) }
        #expect(
            Set(scenarios.map { String($0.id.dropFirst(PrivacyCanary.scenarioPrefix.count)) })
                == Set(InjectionStrategy.allCases.map(\.rawValue)))
        let canaryKeys = PrivacyCanary.canaries.map { $0.keys.map(String.init) }
        for scenario in scenarios {
            #expect(canaryKeys.contains { keys in scenario.keys.starts(with: keys) }, "\(scenario.id)")
        }
    }
}

@Suite struct EgressCheckTests {
    @Test func lsofOutputYieldsRemoteEndpoints() {
        let output = """
            p4242
            f12
            PTCP
            n192.168.1.10:50123->17.253.144.10:443
            f13
            PTCP
            n127.0.0.1:8000
            f14
            PUDP
            n[fe80::1]:5353->[2001:db8::7]:53
            f15
            PTCP
            n*:443
            nbroken->nohost
            """
        #expect(
            LsofOutput.remoteEndpoints(output) == [
                EgressEndpoint(address: "17.253.144.10", port: 443, transport: "TCP"),
                EgressEndpoint(address: "2001:db8::7", port: 53, transport: "UDP"),
            ])
        #expect(LsofOutput.endpoint(":443") == nil)
        #expect(EgressEndpoint(address: "::ffff:127.0.0.1", port: 1, transport: "TCP").isLoopback)
        #expect(!EgressEndpoint(address: "10.0.0.1", port: 1, transport: "TCP").isLoopback)
    }

    @Test func productionAllowsLoopbackAndTheResolvedHostsOnly() async {
        let appcast = EgressEndpoint(address: "203.0.113.5", port: 443, transport: "TCP")
        let other = EgressEndpoint(address: "198.51.100.9", port: 443, transport: "TCP")
        let loopback = EgressEndpoint(address: "127.0.0.1", port: 8000, transport: "TCP")
        let sampler = FakeConnectionSampler(
            samples: [[loopback], [appcast, loopback], [other]], addresses: ["updates.example.org": ["203.0.113.5"]])
        let sleeper = RecordingSleeper()
        let report = await EgressMonitor(sampler: sampler, sleeper: sleeper).run(
            processIdentifier: 1, phase: .production, allowedHosts: ["updates.example.org"], samples: 3,
            intervalNanoseconds: 1_000_000_000)
        #expect(report.samples == 3 && !report.passed)
        #expect(report.connections.map(\.allowed) == [true, false, true])  // sorted: 127..., 198..., 203...
        #expect(report.connections.first { $0.endpoint == other }?.firstSample == 2)
        #expect(sleeper.requests.all == [1_000_000_000, 1_000_000_000])
        #expect(sampler.resolutions.all == ["updates.example.org", "updates.example.org", "updates.example.org"])
    }

    /// Local phase: only loopback; a sample that fails ends the run with what was seen.
    @Test func localAllowsLoopbackOnlyAndStopsWhenTheProcessIsGone() async {
        let sampler = FakeConnectionSampler(samples: [
            [EgressEndpoint(address: "127.0.0.1", port: 8000, transport: "TCP")]
        ])
        let report = await EgressMonitor(sampler: sampler, sleeper: RecordingSleeper()).run(
            processIdentifier: 1, phase: .local, allowedHosts: ["ignored"], samples: 5, intervalNanoseconds: 1)
        #expect(report.samples == 1 && report.passed && report.allowedHosts.isEmpty)
        #expect(sampler.resolutions.all.isEmpty)
    }
}
