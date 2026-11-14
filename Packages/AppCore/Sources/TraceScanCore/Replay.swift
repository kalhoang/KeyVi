// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finding (h), replay divergence (PLT-R904A): from every point where the host reset the engine (a boundary or a
// launch), the recorded keys go through a fresh engine built from the recorded settings and focus; the first step
// whose output differs from the recorded one is flagged. A difference means the host fed the engine something else
// than the keys suggest, or kept state it should have dropped. Steps decided by the user's word lists or a macro
// cannot be reproduced offline (the trace holds only their counts), so the segment stops there without a finding.

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
            autoRestore: settings["englishRestore"] != "false" && focus?.er != false,
            appContext: focus?.ctx == "code" ? .code : .general)
        if let engine = engines[configuration] { return engine }
        let engine = Engine(configuration: configuration, resources: resources)
        engines[configuration] = engine
        return engine
    }
}

enum ReplayCheck {
    static func divergences(in events: [TraceEvent], factory: ReplayEngineFactory) -> [Finding] {
        var found: [Finding] = []
        var context = TraceContext()
        var session: Session?
        var stepIndex = 0
        var key: TraceLine?
        for (position, event) in events.enumerated() {
            let line = event.line
            context.apply(line)
            switch line.type {
            case "start", "boundary":
                session = factory.engine(settings: context.settings, focus: context.focus).map { Session(engine: $0) }
                stepIndex = 0
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
            default: break
            }
        }
        return found
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
