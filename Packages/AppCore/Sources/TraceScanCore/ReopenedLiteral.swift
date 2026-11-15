// SPDX-License-Identifier: GPL-3.0-or-later
//
// The ENG-R1005 regression guard of the scanner (PLT-R904A, ADR 0007 decision 12), finding `reopenedLiteral`. A token
// that a rule restored at its commit (any `restored` decision but the user's own, L1) shows its raw keys when a
// Backspace re-opens it, and keys typed into it are appended as typed; its restore ends at the first Backspace after
// which no remaining raw key transforms anything, and from then on it composes like a token typed afresh. Before that
// rule (15/11/2026, REG-33) the restore lasted until the token ended: `tiesng`, space, five Backspaces, `eesn` showed
// `tieesn`. The tracker follows a re-opened token through its engine steps; a run of keys that passed through as
// typed after at least one Backspace into it is a candidate, and the check replays it through a fresh engine: it is a
// finding only when the token shown before the run composes to itself (the restore should have ended) and the token
// after it does not (a fresh token would have transformed the keys). Any edit in the token means the engine composed
// it, so the token is left alone. The shown token of a restored token is its raw keys, which the recorder already
// writes (`comp`); the finding's detail holds counts and the commit decision only, never a typed character.

internal import Foundation
internal import VietnameseEngine

/// One run of keys typed into a re-opened restored token, as the check needs it.
struct ReopenedLiteralCandidate {
    var decision: String
    /// Backspaces into the token after the one that re-opened it.
    var backspaces: Int
    /// Keys of the run that passed through as typed.
    var keys: Int
    /// The token shown before the run's first key (its remaining raw keys) and after its last.
    var before: String
    var after: String
    /// The engine step of the run's first key, with the app and rule in effect there.
    var event: TraceEvent
    var bundle: String?
    var rule: String?
    var settings: [String: String]
    var focus: TraceLine?

    /// Counts and names only (PLT-R904A summary rule).
    var detail: String {
        "Backspace re-opened a token committed as " + decision + "; after " + Self.counted(backspaces, "Backspace")
            + " into it, " + Self.counted(keys, "key") + " passed through as typed that a fresh token composes "
            + "(ENG-R1005)"
    }

    private static func counted(_ number: Int, _ noun: String) -> String {
        String(number) + " " + noun + (number == 1 ? "" : "s")
    }
}

/// Follows the newest re-opened restored token until it ends; at most one token at a time (the engine has one).
struct ReopenedLiteralTracker {
    private struct Episode {
        var decision: String
        var backspaces = 0
        var keys = 0
        var runStart: (before: String, event: TraceEvent, bundle: String?, rule: String?)?

        /// The run so far, when it can be judged: at least one Backspace into the token and one key passed.
        func run(after: String, context: TraceContext) -> ReopenedLiteralCandidate? {
            guard backspaces > 0, keys > 0, let start = runStart else { return nil }
            return ReopenedLiteralCandidate(
                decision: decision, backspaces: backspaces, keys: keys, before: start.before, after: after,
                event: start.event, bundle: start.bundle, rule: start.rule, settings: context.settings,
                focus: context.focus)
        }
    }

    private var episode: Episode?

    /// A Backspace re-opened a token committed with `decision`. The user's own restore (L1, `userChoice`) stays
    /// literal for the rest of the token on purpose (ENG-R1005, E02b).
    mutating func reopened(decision: String) {
        let ruleRestored = decision.hasPrefix("restored") && decision != "restored(userChoice)"
        episode = ruleRestored ? Episode(decision: decision) : nil
    }

    /// One engine step inside the re-opened token; `before` is the token shown before it. Returns a run to check
    /// when the step ends one: a commit, or a Backspace after keys were typed.
    mutating func step(
        _ line: TraceLine, key: TraceLine?, before: String, event: TraceEvent, context: TraceContext
    ) -> ReopenedLiteralCandidate? {
        guard var current = episode else { return nil }
        if line.dec != nil {
            episode = nil
            return current.run(after: before, context: context)
        }
        guard let key, !line.isEdit else {
            if line.isEdit { episode = nil }  // the engine composes this token: nothing to guard
            return nil
        }
        if key.kc == TraceKeys.backspace {
            let run = current.run(after: before, context: context)
            current.backspaces += 1
            current.keys = 0
            current.runStart = nil
            episode = (line.comp ?? "").isEmpty ? nil : current  // deleted to the end: the token is gone
            return run
        }
        // Keys typed before any Backspace into the token stay as typed (ENG-R1005: `Safar`, space, Backspace, `i`).
        guard current.backspaces > 0, line.act == "passThrough", Self.isTypedKey(key) else { return nil }
        if current.runStart == nil { current.runStart = (before, event, context.bundle, context.rule) }
        current.keys += 1
        episode = current
        return nil
    }

    /// The host reset the engine (a boundary): the token ends as shown.
    mutating func ended(composing: String, context: TraceContext) -> ReopenedLiteralCandidate? {
        defer { episode = nil }
        return episode?.run(after: composing, context: context)
    }

    /// Keys were not recorded (a gap, a pause, a new launch), or the token was reported already.
    mutating func cancel() { episode = nil }

    /// A letter or digit typed without Command, Control or Option (a digit is a transform key in VNI).
    private static func isTypedKey(_ key: TraceLine) -> Bool {
        guard !key.hasCommandOrControl, key.flags & TraceKeys.option == 0, let text = key.ch, text.count == 1,
            let character = text.first
        else { return false }
        return character.isLetter || character.isNumber
    }
}

enum ReopenedLiteralCheck {
    /// The run is a regression: the token before it composes to itself, so its restore should have ended, and a
    /// fresh token with the keys after it composes to something else. Needs the recorded settings.
    static func confirms(_ candidate: ReopenedLiteralCandidate, factory: ReplayEngineFactory) -> Bool {
        guard let engine = factory.engine(settings: candidate.settings, focus: candidate.focus),
            let start = freshDisplay(of: candidate.before, engine), start == candidate.before,
            let end = freshDisplay(of: candidate.after, engine)
        else { return false }
        return end != candidate.after
    }

    /// The display of `keys` typed into a fresh token; nil when a key is not a letter or digit (it could end the
    /// token, so a fresh token says nothing about it).
    static func freshDisplay(of keys: String, _ engine: Engine) -> String? {
        guard keys.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        var session = Session(engine: engine)
        var display = ""
        for character in keys { display = session.handle(.key(KeyInput(character))).composingText }
        return display
    }
}
