// SPDX-License-Identifier: MPL-2.0
//
// Replays fixture keys through a `Session` the way the host drives the engine (spec/02-platform.md PLT-R340,
// PLT-R353; Packages/AppCore InputHost KeyPipeline+Keys.swift): Return and Tab are delivered to the engine and then
// end the composition with a reset (`commitLine`); Escape is the restore binding: the engine's edit consumes it,
// otherwise it passes through and is a hard boundary (`restoreLastWord`). Every event goes through
// `EngineDriver`, so the output contract of ENG-T31 is checked on the whole corpus too. The replay captures, per
// committed token, the raw keys, the decision, the boundary key and the revision that later changed it, and every
// collision signal in order (ENG-R801, ENG-R828, ENG-R864).

import VietnameseEngine
import VietnameseEngineTesting

/// One key as the host classifies it before the engine sees it.
enum HostInput: Hashable {
    case character(Character)
    case returnKey
    case tab
    case escape
    case backspace

    /// Keys as the fixtures write them: characters, `{RET}`, `{TAB}`, `{ESC}` and `{BS}`.
    static func parse(_ keys: String) throws -> [HostInput] {
        var inputs: [HostInput] = []
        var rest = Substring(keys)
        while let first = rest.first {
            if first == "{", let close = rest.firstIndex(of: "}") {
                let name = rest[rest.index(after: rest.startIndex)..<close]
                switch name {
                case "RET": inputs.append(.returnKey)
                case "TAB": inputs.append(.tab)
                case "ESC": inputs.append(.escape)
                case "BS": inputs.append(.backspace)
                default: throw FixtureFormatError(file: "keys", line: 0, reason: "unknown key {\(name)}")
                }
                rest = rest[rest.index(after: close)...]
            } else {
                inputs.append(.character(first))
                rest = rest.dropFirst()
            }
        }
        return inputs
    }
}

/// A correction the scripted user of the memory simulation makes, addressed by token index (ENG-R864 strong
/// signals; the planner in MemorySimulation.swift picks the kind).
enum Correction: Hashable {
    /// Backspace re-opens the token right after its commit, Escape toggles it, its boundary key commits it again
    /// (ENG-R704).
    case afterCommit(Int)
    /// Escape on the active token before Return or Tab ends it (ENG-R701: shows the raw keys).
    case beforeBoundary(Int)
    /// Escape right after the commit of the next token, which revised this one (ENG-R829).
    case undoRevision(Int)
}

/// One committed token of a replay.
struct ReplayedToken: Hashable {
    let raw: String
    /// The decision of its last commit (a corrected token's re-commit replaces the first one).
    var decision: CommitDecision
    let boundary: Character
    /// The revision that changed it when the next token committed (ENG-R828), nil after an undo.
    var revision: RevisionReason?
    /// The token was re-opened and committed again, or its revision was undone.
    var corrected = false
}

/// What one replay produced.
struct ReplayResult {
    let field: String
    let tokens: [ReplayedToken]
    let signals: [CollisionSignal]

    /// The field in fixture notation (`{RET}` for a line break, `{TAB}` for a tab).
    var notation: String {
        field.replacingOccurrences("\n", with: "{RET}").replacingOccurrences("\t", with: "{TAB}")
    }

    /// The words of the field: runs of letters, in order (they align with the tokens and the fixture words).
    var words: [String] {
        field.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
}

/// The host-mode replay of one line of keys.
struct HostReplay {
    let engine: Engine

    func run(_ inputs: [HostInput], corrections: Set<Correction> = []) throws -> ReplayResult {
        var state = ReplayState(driver: EngineDriver(engine: engine))
        for input in inputs {
            let isLineEnd = input == .returnKey || input == .tab
            if isLineEnd, state.hasActiveToken, corrections.contains(.beforeBoundary(state.tokens.count)) {
                try state.press(.escape)
            }
            let before = state.tokens.count
            try state.press(input)
            guard state.tokens.count > before else { continue }
            let committed = state.tokens.count - 1
            // The undo must be the very next event after the revising commit (ENG-R829), so it comes first.
            if committed >= 1, state.revisedByLastCommit == committed - 1,
                corrections.contains(.undoRevision(committed - 1))
            {
                try state.press(.escape)
            }
            if corrections.contains(.afterCommit(committed)), !isLineEnd {
                try state.press(.backspace)
                try state.press(.escape)
                try state.press(input)
            }
        }
        return ReplayResult(field: state.driver.field.string, tokens: state.tokens, signals: state.signals)
    }
}

/// The mutable side of one replay.
private struct ReplayState {
    var driver: EngineDriver
    var tokens: [ReplayedToken] = []
    var signals: [CollisionSignal] = []
    /// Backspace re-opened the newest token: its next commit replaces it instead of adding a token.
    var reopened = false
    /// The previous event was a commit that revised the token before it (index of that token).
    var revisedByLastCommit: Int?

    var hasActiveToken: Bool { !driver.state.activeRawKeys.isEmpty }

    mutating func press(_ input: HostInput) throws {
        switch input {
        case .character(let character):
            try send(.key(KeyInput(character)))
        case .returnKey, .tab:
            // PLT-R340: the line key reaches the engine, then the host ends the composition (commitLine).
            try send(.key(KeyInput(input == .returnKey ? "\n" : "\t")))
            try send(.reset(.cursorMoved))
        case .escape:
            // PLT-R353: an edit consumes Escape; otherwise it passes through and is a hard boundary.
            let output = try send(.restoreToggle)
            if !Self.isNonEmptyEdit(output) { try send(.reset(.shortcut)) }
        case .backspace:
            try send(.backspace)
        }
    }

    @discardableResult
    mutating func send(_ event: EngineEvent) throws -> EngineOutput {
        let raw = driver.state.activeRawKeys
        let undoTarget = revisedByLastCommit
        revisedByLastCommit = nil
        let output = try driver.send(event)
        signals += output.collisionSignals
        switch event {
        case .key(let key):
            if let decision = output.decision { record(decision, raw: raw, boundary: key.character, output: output) }
        case .backspace:
            if raw.isEmpty, hasActiveToken { reopened = true }
        case .restoreToggle:
            if let undoTarget, Self.isNonEmptyEdit(output) {
                tokens[undoTarget].revision = nil
                tokens[undoTarget].corrected = true
            }
        case .reset:
            reopened = false
        }
        return output
    }

    private mutating func record(_ decision: CommitDecision, raw: String, boundary: Character, output: EngineOutput) {
        if reopened, let last = tokens.indices.last {
            reopened = false
            tokens[last].decision = decision
            tokens[last].corrected = true
            if let reason = output.revision, last >= 1 {
                tokens[last - 1].revision = reason
                revisedByLastCommit = last - 1
            }
            return
        }
        if let reason = output.revision, let previous = tokens.indices.last {
            tokens[previous].revision = reason
            revisedByLastCommit = previous
        }
        tokens.append(ReplayedToken(raw: raw, decision: decision, boundary: boundary))
    }

    static func isNonEmptyEdit(_ output: EngineOutput) -> Bool {
        guard case .edit(let edit, _) = output.action else { return false }
        return edit.deleteCount > 0 || !edit.insert.isEmpty
    }
}

extension String {
    /// Every occurrence of `target` replaced (standard library only).
    fileprivate func replacingOccurrences(_ target: String, with replacement: String) -> String {
        split(separator: Character(target), omittingEmptySubsequences: false).joined(separator: replacement)
    }
}
