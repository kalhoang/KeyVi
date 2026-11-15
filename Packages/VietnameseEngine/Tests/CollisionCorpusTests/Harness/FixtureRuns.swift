// SPDX-License-Identifier: MPL-2.0
//
// The replays the QA-R68 gate scores, computed once per test process and shared by the tests: every fixture file
// through the engine with the bundled data in host mode, with the collision rules (`lookaheadRevision` on, the
// default) and, for the corpus, without them (ENG-R829: off, the engine decides as it did before the rules).

import Foundation
import VietnameseEngine
import VietnameseEngineData

/// The bundled resources with empty user lists, no macros and an empty learned memory.
enum GateResources {
    private static let loaded = Result { () throws -> Resources in
        try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
    }

    static func bundled() throws -> Resources { try loaded.get() }

    /// The default engine (Telex, defaults) over the bundled data with `memory`, in `appContext` (ENG-R850).
    static func engine(
        lookaheadRevision: Bool = true, appContext: AppContext = .general, memory: CollisionMemorySnapshot = .empty
    ) throws -> Engine {
        var resources = try bundled()
        resources.collisionMemory = memory
        return Engine(
            configuration: EngineConfiguration(appContext: appContext, lookaheadRevision: lookaheadRevision),
            resources: resources)
    }
}

/// One fixture file and its replays.
struct FixtureRuns {
    let fixture: CorpusFixture
    let header: [String]
    let sentences: [CorpusSentence]
    /// With the collision rules.
    let on: [ReplayResult]
    /// Without them (`lookaheadRevision` off); nil for the adversarial sets.
    let off: [ReplayResult]?

    var score: CorpusScore { CorpusScore.score(sentences, on, baseline: off) }

    private init(_ fixture: CorpusFixture, withBaseline: Bool) throws {
        let (header, sentences) = try fixture.load()
        let inputs = try sentences.map { try HostInput.parse($0.keys) }
        let on = HostReplay(engine: try GateResources.engine())
        self.fixture = fixture
        self.header = header
        self.sentences = sentences
        self.on = try inputs.map { try on.run($0) }
        if withBaseline {
            let off = HostReplay(engine: try GateResources.engine(lookaheadRevision: false))
            self.off = try inputs.map { try off.run($0) }
        } else {
            self.off = nil
        }
    }

    private static let toneLast = Result { try FixtureRuns(.toneLast, withBaseline: true) }
    private static let toneAfterVowel = Result { try FixtureRuns(.toneAfterVowel, withBaseline: true) }
    private static let adversarial = Result { try FixtureRuns(.adversarial, withBaseline: false) }
    private static let stress = Result { try FixtureRuns(.stress, withBaseline: false) }
    private static let heldOut = Result { try FixtureRuns(.heldOut, withBaseline: false) }

    /// The shared replays of `fixture`.
    static func of(_ fixture: CorpusFixture) throws -> FixtureRuns {
        switch fixture {
        case .toneLast: try toneLast.get()
        case .toneAfterVowel: try toneAfterVowel.get()
        case .adversarial: try adversarial.get()
        case .stress: try stress.get()
        case .heldOut: try heldOut.get()
        }
    }

    /// QA-R68 update path: with `COLLISION_CORPUS_RECORD=<directory>` in the environment, writes the fixture with
    /// the expected and revised columns of this replay to `<directory>/<file>.tsv`, for review with the change that
    /// moved them (QA-R6). Returns the path written, nil when the variable is not set.
    @discardableResult
    func recordIfRequested() throws -> String? {
        guard let directory = ProcessInfo.processInfo.environment["COLLISION_CORPUS_RECORD"], !directory.isEmpty
        else { return nil }
        let raw = try String(contentsOf: try fixture.url, encoding: .utf8)
        var lines: [String] = []
        var index = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.hasPrefix("#"), !line.isEmpty else {
                lines.append(String(line))
                continue
            }
            var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let result = on[index]
            fields[4] = result.notation
            let revised = result.tokens.enumerated().compactMap { offset, token in
                token.revision.map { "\(offset):\(RevisionName.of($0))" }
            }
            fields[5] = revised.isEmpty ? "-" : revised.joined(separator: ",")
            lines.append(fields.joined(separator: "\t"))
            index += 1
        }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("\(fixture.rawValue).tsv")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }
}
