// SPDX-License-Identifier: MPL-2.0
//
// Types one demo through the engine and a simulated text field (ENG-T31) and keeps a frame after every key.
// Nothing is invented: every text is the field a host would show, every commit the engine's own decision, every plain
// form what the engine shows with auto restore off (ENG-R802). Learning demos: FrameRecorder+Learning.swift.

import VietnameseEngine
import VietnameseEngineTesting

/// A demo as the engine typed it: a frame per key and the final field text.
struct RecordedDemo: Sendable, Hashable {
    /// What a commit at a boundary did to the token (ENG-R801).
    struct Commit: Sendable, Hashable {
        /// The token's raw keys before the boundary (ENG-R602).
        let raw: String
        /// What the token became on screen.
        let text: String
        /// `kept`, `restored` or `macro`.
        let outcome: String
        /// The ``CommitRule`` case name; nil for a macro.
        let rule: String?
        /// The token is shown exactly as typed and is not Vietnamese: restored by a rule, or kept as typed while
        /// it is not a Vietnamese syllable (`online`, `file`). The website tags these words as kept.
        let english: Bool
        /// For an English token, what plain Telex (or VNI) would have typed: the display of `raw` typed alone with
        /// auto restore and the revision off (ENG-R802), when it differs from `text` (`test` gives `tét`). The
        /// website's tag names it ("test, không thành tét"); nil for a word plain typing leaves as is (`online`).
        let plain: String?
    }

    /// What a revision made of the previous token (ENG-R828), read from the engine's history after the commit.
    struct Revised: Sendable, Hashable {
        /// The previous token's raw keys (ENG-R602).
        let raw: String
        /// What the previous token shows now.
        let text: String
        /// The same rule as ``Commit/english``: the previous token is now shown exactly as typed and is not
        /// Vietnamese. The website tags it as kept, as for a commit.
        let english: Bool
        /// The same as ``Commit/plain``, for the previous token.
        let plain: String?
    }

    /// The field after one key.
    struct Frame: Sendable, Hashable {
        /// The key in the script's notation.
        let key: String
        /// The whole field after the key.
        let text: String
        /// Set when the key committed a token.
        let commit: Commit?
        /// Set when the commit also revised the previous token (ENG-R828): the token and what it became.
        let revised: Revised?
        /// The key was the restore toggle (Escape).
        let toggle: Bool

        /// The commit also revised the previous token (ENG-R828).
        var revision: Bool { revised != nil }
    }

    /// One teaching pass of a learning demo (design 9 item 4): the teaching keys typed in a fresh field.
    struct TeachingPass: Sendable, Hashable {
        /// The field after the pass.
        let text: String
        let frames: [Frame]
        /// Every collision signal of the pass, in order: what the learned memory counted after it (ENG-R863). Not
        /// written to the frames file.
        let signals: [CollisionSignal]
    }

    let id: String
    let keys: String
    let method: DemoScript.Method
    let toneStyle: DemoScript.ToneStyle
    /// The field after the last key.
    let text: String
    let frames: [Frame]
    /// The keys of one teaching pass; nil unless this is a learning demo.
    let teachKeys: String?
    /// The teaching passes typed before `keys`, in order; empty unless this is a learning demo.
    let teachPasses: [TeachingPass]
}

/// Records demos with one engine per configuration and a fresh simulated field per demo.
struct FrameRecorder: Sendable {
    /// The engine broke its output contract, or a commit's text cannot be found in the field.
    struct Failure: Error, Sendable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct Settings: Sendable, Hashable {
        let method: DemoScript.Method
        let toneStyle: DemoScript.ToneStyle
    }

    /// One run of keys through a fresh field: the field after the last key, a frame per key and every collision
    /// signal the outputs carried.
    struct Typed: Sendable {
        let text: String
        let frames: [RecordedDemo.Frame]
        let signals: [CollisionSignal]
    }

    /// The field and the active token just before a key.
    private struct Before {
        let field: String
        let display: String
        let raw: String
    }

    /// The resources every engine starts from: no user lists, no macros and, as given, no learned memory.
    let resources: Resources
    /// The demo engines, one per configuration.
    private let engines: [Settings: Engine]
    /// The engines that give the plain forms (ENG-R802), one per configuration.
    private let plainEngines: [Settings: Engine]

    init(resources: Resources) {
        self.resources = resources
        let settings = DemoScript.Method.allCases.flatMap { method in
            DemoScript.ToneStyle.allCases.map { Settings(method: method, toneStyle: $0) }
        }
        engines = Dictionary(
            uniqueKeysWithValues: settings.map {
                ($0, Engine(configuration: Self.configuration($0), resources: resources))
            })
        plainEngines = Dictionary(
            uniqueKeysWithValues: settings.map {
                ($0, Engine(configuration: Self.plainConfiguration($0), resources: resources))
            })
    }

    /// Every demo runs in a general-context field with auto restore and the next-word revision on (D29) and no
    /// macros (design 7.4); only the typing method and the tone placement vary.
    static func configuration(_ settings: Settings) -> EngineConfiguration {
        EngineConfiguration(
            inputMethod: settings.method == .telex ? .telex(TelexOptions()) : .vni,
            toneStyle: settings.toneStyle == .traditional ? .traditional : .modern,
            autoRestore: true, appContext: .general, lookaheadRevision: true, typoCorrection: false)
    }

    /// Plain typing, the reference of a kept word's plain form: the same method and tone placement with auto restore
    /// and the revision off, so no rule restores anything (ENG-R802).
    static func plainConfiguration(_ settings: Settings) -> EngineConfiguration {
        var configuration = configuration(settings)
        configuration.autoRestore = false
        configuration.lookaheadRevision = false
        return configuration
    }

    /// Types `demo` key by key and keeps the field after each key; a learning demo is taught first.
    func record(_ demo: DemoScript.Demo) throws -> RecordedDemo {
        let settings = Settings(method: demo.method, toneStyle: demo.toneStyle)
        if let teaching = demo.teaching { return try recordLearning(demo, teaching, settings: settings) }
        guard let engine = engines[settings] else {
            throw Failure("\(demo.id): no engine for \(demo.method) \(demo.toneStyle)")
        }
        let typed = try type(demo.keys, engine: engine, settings: settings, demo: demo.id)
        return RecordedDemo(
            id: demo.id, keys: demo.keys, method: demo.method, toneStyle: demo.toneStyle, text: typed.text,
            frames: typed.frames, teachKeys: nil, teachPasses: [])
    }

    /// Types `keys` into a fresh field with `engine` and keeps the field after each key.
    func type(_ keys: String, engine: Engine, settings: Settings, demo: String) throws -> Typed {
        guard let plainEngine = plainEngines[settings] else {
            throw Failure("\(demo): no plain engine for \(settings.method) \(settings.toneStyle)")
        }
        let plain = { (raw: String, text: String) in try Self.plain(raw, text: text, engine: plainEngine, demo: demo) }
        var driver = EngineDriver(engine: engine)
        var frames: [RecordedDemo.Frame] = []
        var signals: [CollisionSignal] = []
        for key in DemoKey.parse(keys) {
            let before = Before(
                field: driver.field.string, display: driver.state.activeDisplay, raw: driver.state.activeRawKeys)
            let output: EngineOutput
            do {
                output = try driver.send(key.event)
            } catch {
                throw Failure("\(demo): key \(frames.count + 1) breaks the output contract: \(error)")
            }
            signals += output.collisionSignals
            let field = driver.field.string
            let body = Self.deliversKey(output, key) ? String(field.dropLast()) : field
            let commit = try output.decision.map {
                try Self.commit($0, output: output, before: before, body: body, demo: demo, plain: plain)
            }
            let revised = try output.revision.map { _ in
                try Self.revised(driver.state, body: body, commit: commit, demo: demo, plain: plain)
            }
            frames.append(
                RecordedDemo.Frame(
                    key: key.notation, text: field, commit: commit, revised: revised, toggle: key.isToggle))
        }
        return Typed(text: driver.field.string, frames: frames, signals: signals)
    }

    /// ENG-R802: what `engine` (auto restore and the revision off) shows after `raw` typed alone into a fresh field,
    /// the composed display before any boundary; nil when it is `text`.
    private static func plain(_ raw: String, text: String, engine: Engine, demo: String) throws -> String? {
        var driver = EngineDriver(engine: engine)
        do {
            try driver.send(raw.map { .key(KeyInput($0)) })
        } catch {
            throw Failure("\(demo): typing \(String(reflecting: raw)) alone breaks the output contract: \(error)")
        }
        let display = driver.state.activeDisplay
        return display == text ? nil : display
    }

    /// The commit a key made, read from the field: without a revision the token is what follows the unchanged text
    /// before it; with one (the edit also covers the previous token, ENG-R803) it is the composed form or the raw
    /// keys, whichever the decision names, and the field must end with it.
    /// `body` is the field without the boundary key the app received after the edit.
    private static func commit(
        _ decision: CommitDecision, output: EngineOutput, before: Before, body: String, demo: String,
        plain: (String, String) throws -> String?
    ) throws -> RecordedDemo.Commit {
        let prefix = String(before.field.dropLast(before.display.count))
        let text: String
        switch (output.revision, decision) {
        case (nil, _):
            guard body.hasPrefix(prefix) else { throw Failure("\(demo): a commit changed the text before its token") }
            text = String(body.dropFirst(prefix.count))
        case (_, .kept): text = before.display
        case (_, .restored): text = before.raw
        case (_, .macro): throw Failure("\(demo): a macro expansion revised the previous token")
        // ENG-R1116: a commit never both revises and corrects; the frames run with the switch off anyway.
        case (_, .corrected): throw Failure("\(demo): a typo correction revised the previous token")
        }
        guard body.hasSuffix(text) else { throw Failure("\(demo): the field does not end with the committed token") }
        let english = isEnglish(text: text, raw: before.raw, restoredByRule: decision.isRestored)
        return RecordedDemo.Commit(
            raw: before.raw, text: text, outcome: decision.outcome, rule: decision.rule?.name, english: english,
            plain: english ? try plain(before.raw, text) : nil)
    }

    /// The previous token after a revision: the token before the one just committed in the engine's history
    /// (ENG-R1001). The field must end with it, the boundaries after it and the committed token (ENG-R803).
    private static func revised(
        _ state: EngineState, body: String, commit: RecordedDemo.Commit?, demo: String,
        plain: (String, String) throws -> String?
    ) throws -> RecordedDemo.Revised {
        guard let commit else { throw Failure("\(demo): a revision without a commit") }
        let entries = Array(state.history.entries)
        let tokens = entries.indices.filter { if case .token = entries[$0] { true } else { false } }
        guard tokens.count >= 2, case .token(let current) = entries[tokens[tokens.count - 1]],
            case .token(let previous) = entries[tokens[tokens.count - 2]], current.committedText == commit.text
        else { throw Failure("\(demo): the history does not hold the revised token before the committed one") }
        let between = entries[(tokens[tokens.count - 2] + 1)..<tokens[tokens.count - 1]].map(\.text).joined()
        guard body.hasSuffix(previous.committedText + between + commit.text) else {
            throw Failure("\(demo): the field does not end with the revised token")
        }
        let raw = previous.token.rawText
        let english = isEnglish(text: previous.committedText, raw: raw, restoredByRule: previous.showsRawKeysByRule)
        return RecordedDemo.Revised(
            raw: raw, text: previous.committedText, english: english,
            plain: english ? try plain(raw, previous.committedText) : nil)
    }

    /// The token is shown exactly as typed and is not Vietnamese: a rule restored it, or its keys are not a
    /// Vietnamese syllable (`online`, `file`). A Vietnamese syllable typed unchanged (`nay`) is not English.
    private static func isEnglish(text: String, raw: String, restoredByRule: Bool) -> Bool {
        text == raw && raw.contains(where: \.isLetter)
            && (restoredByRule || Orthography.validity(of: raw) == .invalid)
    }

    /// The original key reached the field after the edit (a boundary character the app receives, ENG-R803).
    private static func deliversKey(_ output: EngineOutput, _ key: DemoKey) -> Bool {
        guard case .key = key.event else { return false }
        switch output.action {
        case .passThrough: return true
        case .edit(_, let thenPassThrough): return thenPassThrough
        }
    }
}

extension CommitDecision {
    /// `kept`, `restored`, `macro` or `corrected` (section 11A).
    var outcome: String {
        switch self {
        case .kept: "kept"
        case .restored: "restored"
        case .macro: "macro"
        case .corrected: "corrected"
        }
    }

    var isRestored: Bool {
        if case .restored = self { return true }
        return false
    }

    /// The rule of spec 8.1 that decided (for a correction, the rule that would have decided); nil for a macro.
    var rule: CommitRule? {
        switch self {
        case .kept(let rule), .restored(let rule), .corrected(let rule): rule
        case .macro: nil
        }
    }
}

extension CommitRule {
    /// The case name, written into the frames file (ENG-R801 reason codes).
    var name: String {
        switch self {
        case .unchanged: "unchanged"
        case .userChoice: "userChoice"
        case .userList: "userList"
        case .abbreviation: "abbreviation"
        case .camelCase: "camelCase"
        case .escape: "escape"
        case .toneRemoval: "toneRemoval"
        case .invalid: "invalid"
        case .extendedSpelling: "extendedSpelling"
        case .notEnglish: "notEnglish"
        case .notAttested: "notAttested"
        case .codeContext: "codeContext"
        case .boundaryParticle: "boundaryParticle"
        case .phrase: "phrase"
        case .learned: "learned"
        case .englishRun: "englishRun"
        case .ambiguityTable: "ambiguityTable"
        case .techList: "techList"
        case .defaultVietnamese: "defaultVietnamese"
        }
    }
}
