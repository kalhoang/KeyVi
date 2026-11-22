// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finding (h), replay divergence (PLT-R904A): from every point where the host reset the engine (a boundary or a
// launch), the recorded keys go through a fresh engine built from the recorded settings and focus; the first step
// whose output differs from the recorded one is flagged. A difference means the host fed the engine something else
// than the keys suggest, or kept state it should have dropped. Steps decided by the user's word lists or a macro
// cannot be reproduced offline (the trace holds only their counts), so the segment stops there without a finding.
// A segment also stops at a gap or a pause (keys inside are not recorded), and segments written by another engine
// build than the scanner's, or by one that did not record its identity, are not replayed: the summary counts them
// (ADR 0007 decision 13), unless `--replay-anyway` asks for the old behaviour. Return and Tab are fed to the engine
// before their boundary (KeyPipeline `commitLine`), but the recorder writes the boundary when it happens and the key's
// engine step after the key, so that boundary applies after the key's own step (day finding 155 of 15/11/2026).

internal import Diagnostics
internal import Foundation
public import VietnameseEngine
internal import VietnameseEngineData

/// Engines for replay over the bundled lexicons, one per configuration.
public final class ReplayEngineFactory {
    private let resources: Resources
    private var engines: [EngineConfiguration: Engine] = [:]

    public init(resources: Resources) { self.resources = resources }

    /// The lexicons the app ships, without user word lists or macros.
    public static func bundled() throws -> ReplayEngineFactory {
        ReplayEngineFactory(resources: try bundledResources())
    }

    static func bundledResources() throws -> Resources {
        try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
    }

    /// The engine identity of this scanner (ADR 0007 decision 13): the digest of the probes through its engine with
    /// the default configuration, computed exactly as the recorder computes it (InputHost
    /// `DevEngineIdentity.ofLinkedEngine`). A trace written by another identity is not replayed.
    public private(set) lazy var identity: String = DevEngineIdentity.digest { [resources] vni in
        let method: InputMethod = vni ? .vni : .telex(TelexOptions())
        // The configuration of InputHost `DevEngineIdentity.ofLinkedEngine`: the product's default, typo correction
        // on (D30, ENG-R1119), so that the identity follows the engines the app runs.
        var session = Session(
            engine: Engine(
                configuration: EngineConfiguration(inputMethod: method, typoCorrection: true), resources: resources))
        return { character in
            switch session.handle(.key(KeyInput(character))).action {
            case .passThrough: .passThrough
            case .edit(let edit, let thenPassThrough):
                .edit(deleteCount: edit.deleteCount, insert: edit.insert, thenPassThrough: thenPassThrough)
            }
        }
    }

    /// Nil when the settings line has not been seen (no replay without the method and tone placement).
    func engine(settings: [String: String], focus: TraceLine?) -> Engine? {
        guard let method = settings["typingMethod"], let tone = settings["tonePlacement"] else { return nil }
        let inputMethod: InputMethod =
            method == "vni"
            ? .vni
            : .telex(
                TelexOptions(
                    standaloneW: settings["telexStandaloneW"] != "false",
                    bracketKeys: settings["telexBracketKeys"] == "true"))
        let configuration = EngineConfiguration(
            inputMethod: inputMethod, toneStyle: tone == "modern" ? .modern : .traditional,
            autoRestore: Self.autoRestore(settings: settings, focus: focus),
            appContext: focus?.ctx == "code" ? .code : .general,
            typoCorrection: Self.typoCorrection(settings: settings, focus: focus))
        if let engine = engines[configuration] { return engine }
        let engine = Engine(configuration: configuration, resources: resources)
        engines[configuration] = engine
        return engine
    }

    /// D4 AND the rule's `features.englishRestore`, as the host passes `autoRestore`.
    static func autoRestore(settings: [String: String], focus: TraceLine?) -> Bool {
        settings["englishRestore"] != "false" && focus?.er != false
    }

    /// ENG-R1119: the typo correction switch of the recorded engine, rebuilt with the conjunction the host passes
    /// (InputHost `EngineSettingsMapping.typoCorrection(_:variant:)`), input for input: the user's D30 (`typoCorrection`
    /// in the settings line) AND D4 AND the rule's `englishRestore` (`er`) AND the rule's `restoreHotkey` (`rhk`) AND a
    /// restore key (D8, `restoreHotkey` not `none`). A settings line without `typoCorrection` was written by a build
    /// whose engines never corrected (1.0.x, and 1.1.0 before the host wired the switch), so its segments replay with
    /// the switch off, as they ran. `ReplayTypoCorrectionTests` pins the agreement with the host for every combination.
    static func typoCorrection(settings: [String: String], focus: TraceLine?) -> Bool {
        settings["typoCorrection"] == "true" && autoRestore(settings: settings, focus: focus) && focus?.rhk != false
            && (settings["restoreHotkey"] ?? "none") != "none"
    }
}

/// Replay segments not replayed because another or an unknown engine build wrote them.
public struct ReplaySkips: Sendable, Hashable {
    public var otherEngine = 0
    public var unidentifiedEngine = 0
    public var total: Int { otherEngine + unidentifiedEngine }

    public init(otherEngine: Int = 0, unidentifiedEngine: Int = 0) {
        self.otherEngine = otherEngine
        self.unidentifiedEngine = unidentifiedEngine
    }
}

enum ReplayCheck {
    static func divergences(in events: [TraceEvent], factory: ReplayEngineFactory) -> [Finding] {
        run(in: events, factory: factory, anyEngine: false).findings
    }

    /// `anyEngine`: replay whatever engine wrote the trace (`--replay-anyway`).
    static func run(in events: [TraceEvent], factory: ReplayEngineFactory, anyEngine: Bool) -> (
        findings: [Finding], skips: ReplaySkips
    ) {
        var found: [Finding] = []
        var skips = ReplaySkips()
        var context = TraceContext()
        var session: Session?
        var stepIndex = 0
        var key: TraceLine?
        /// A Return or Tab boundary waiting for that key's own engine step (its time).
        var deferredReset: Int64?
        func reset() {
            deferredReset = nil
            stepIndex = 0
            session = nil
            guard let engine = factory.engine(settings: context.settings, focus: context.focus) else { return }
            guard anyEngine || context.engine == factory.identity else {
                if context.engine == nil { skips.unidentifiedEngine += 1 } else { skips.otherEngine += 1 }
                return
            }
            session = Session(engine: engine)
        }
        for (position, event) in events.enumerated() {
            let line = event.line
            if let pending = deferredReset, !(line.type == "engine" && line.t == pending) { reset() }
            context.apply(line)
            switch line.type {
            case "boundary" where Self.endsALineAfterItsStep(line, key: key):
                deferredReset = line.t
            case "start", "boundary":
                reset()
            case "gap", "pause":
                session = nil  // keys inside were not recorded; the next boundary or launch starts again
            case "key" where line.isKeyDown:
                key = line
            case "engine":
                guard var current = session else { continue }
                stepIndex += 1
                let next = position + 1 < events.count ? events[position + 1].line : nil
                let restore = next.map { $0.type == "engine" && $0.t == line.t } ?? false
                guard let key, key.t == line.t, let input = input(for: key, restore: restore),
                    !(line.dec ?? "").contains("userList"), !(line.dec ?? "").contains("macro")
                else {
                    session = nil  // the rest of this segment cannot be reproduced
                    continue
                }
                let output = current.handle(input)
                if let difference = difference(recorded: line, replayed: output) {
                    found.append(
                        Finding(
                            kind: .replayDivergence, t: line.t, eventIndex: event.index, bundle: context.bundle,
                            rule: context.rule, detail: "step " + String(stepIndex) + " after the reset: " + difference)
                    )
                    session = nil
                } else {
                    session = current
                }
                if deferredReset == line.t { reset() }
            default: break
            }
        }
        return (found, skips)
    }

    /// The boundary of a Return or Tab key down at the same time: the pipeline took it after the key's engine step.
    static func endsALineAfterItsStep(_ line: TraceLine, key: TraceLine?) -> Bool {
        guard line.job == "returnOrTab", let key, key.t == line.t, key.isKeyDown else { return false }
        return [TraceKeys.returnKey, TraceKeys.keypadEnter, TraceKeys.tab].contains(key.kc ?? 0)
    }

    /// The engine event the pipeline built from this key (PLT-R310 step 7): a restore binding, Backspace, Return
    /// or Tab, or the layout character with its keypad and Caps Lock flags.
    static func input(for key: TraceLine, restore: Bool) -> EngineEvent? {
        if restore || key.out == "consumedAsHotkey" { return .restoreToggle }
        switch key.kc {
        case TraceKeys.backspace?: return .backspace
        case TraceKeys.returnKey?, TraceKeys.keypadEnter?: return .key(KeyInput("\n"))
        case TraceKeys.tab?: return .key(KeyInput("\t"))
        default: break
        }
        guard let text = key.ch, text.count == 1, let character = text.first else { return nil }
        return .key(
            KeyInput(
                character, fromKeypad: TraceKeys.isKeypadCharacter(key.kc ?? 0),
                capsLock: key.flags & TraceKeys.capsLock != 0))
    }

    /// Content-free description of the first difference, or nil when the outputs agree.
    static func difference(recorded line: TraceLine, replayed output: EngineOutput) -> String? {
        let replayedAction: String
        var replayedDelete = 0
        var replayedInsert = ""
        switch output.action {
        case .passThrough: replayedAction = "passThrough"
        case .edit(let edit, let thenPassThrough):
            replayedAction = thenPassThrough ? "editThenPassThrough" : "edit"
            replayedDelete = edit.deleteCount
            replayedInsert = edit.insert
        }
        let recordedInsert = line.ins ?? ""
        let recordedToken = line.comp ?? ""
        let same =
            replayedAction == line.act && replayedDelete == (line.del ?? 0) && replayedInsert == recordedInsert
            && output.composingText == recordedToken
        guard !same else { return nil }
        func describe(_ action: String?, _ delete: Int, _ insert: String, _ token: String) -> String {
            (action ?? "?") + " -" + String(delete) + " +" + String(insert.count) + ", token of " + String(token.count)
        }
        return "recorded " + describe(line.act, line.del ?? 0, recordedInsert, recordedToken) + "; replayed "
            + describe(replayedAction, replayedDelete, replayedInsert, output.composingText)
            + (replayedInsert == recordedInsert && output.composingText == recordedToken ? "" : " (text differs)")
    }
}
