// SPDX-License-Identifier: MPL-2.0
//
// Measurement harness of the undo of a context restore (spec/01-engine.md ENG-R706, REG-42). No target of this
// repository compiles this file: prepare-tree.sh copies it into Tests/VietnameseEngineDataTests/RealData/ of a scratch
// export of the package, and run-tree.sh runs it there (README.md in this directory). It reads only what the engine
// of 1.1.0-beta.1 (28dbd6d0) already has, so the same file runs against the base and the head.
//
// Types each line of $CRM_INPUT (KeyNotation: `⌫` Backspace, `⎋` the restore key; and here `↵` Return, `⇥` Tab) from
// an empty field with the bundled data, Telex defaults and typoCorrection on when $CRM_CORRECTION is 1, off otherwise,
// and writes one line per input to $CRM_OUTPUT: the number of restore keys that came right after a commit ENG-R706
// covers (the flag; recomputed here from each commit's output and the history, never from the engine's own mark),
// a tab, the final field, a tab and a 64-bit FNV-1a hash of every event's field and output (actions, decisions,
// learning and collision signals), so a difference that a later key hides still counts. A newline or tab in the field
// is written as `\n` or `\t`. Without $CRM_INPUT the test does nothing.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("context restore measurement")
struct ContextRestoreMeasureTests {
    @Test func typesEveryInputLine() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["CRM_INPUT"], let output = environment["CRM_OUTPUT"] else { return }
        let configuration = EngineConfiguration(typoCorrection: environment["CRM_CORRECTION"] == "1")
        let engine = Engine(configuration: configuration, resources: try RealData.resources())
        let text = try String(contentsOfFile: input, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result = ""
        result.reserveCapacity(lines.count * 48)
        for line in lines.dropLast(lines.last?.isEmpty == true ? 1 : 0) {
            result += try Self.row(typing: String(line), engine: engine)
        }
        try result.write(toFile: output, atomically: true, encoding: .utf8)
    }

    /// One output line for one input line.
    private static func row(typing line: String, engine: Engine) throws -> String {
        let keys = line.replacingOccurrences(of: "↵", with: "\n").replacingOccurrences(of: "⇥", with: "\t")
        var driver = EngineDriver(engine: engine)
        var hash = FNV1a()
        var flagged = 0
        var previous: EngineOutput?
        for event in KeyNotation.events(keys) {
            if case .restoreToggle = event, let previous, followsCoveredRestore(previous, driver.state, engine) {
                flagged += 1
            }
            let output = try driver.send(event)
            hash.add(driver.field.string)
            hash.add(String(describing: output))
            previous = output
        }
        return "\(flagged)\t\(escaped(driver.field.string))\t\(hash.hex)\n"
    }

    /// The previous event was a commit whose rule restored the token because of the tokens before it (L10 or L9b), the
    /// token alone keeping its composed form (rule L11 keeps the raw keys: a `vi` or unreviewed row, or no row and no
    /// tech-always word), with no revision of the token before it, at an ASCII boundary that keeps the history; the
    /// restored text differs from the composed form (ENG-R706).
    private static func followsCoveredRestore(_ output: EngineOutput, _ state: EngineState, _ engine: Engine) -> Bool {
        guard output.revision == nil,
            output.decision == .restored(.englishRun) || output.decision == .restored(.phrase),
            state.active == nil, case .boundary(let boundary)? = state.history.entry(beforeNewest: 0),
            boundary.asciiValue != nil, let token = state.history.token(beforeNewest: 1),
            token.collision.composed != token.committedText
        else { return false }
        let raw = token.collision.rawLowercased
        switch engine.resources.ambiguity[raw] {
        case .english: return false
        case .vietnamese: return true
        case nil: return !engine.resources.techAlways.contains(raw)
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// 64-bit FNV-1a over the UTF-8 bytes of the strings added, each followed by a 0x1F separator.
private struct FNV1a {
    private var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func add(_ text: String) {
        for byte in text.utf8 { mix(byte) }
        mix(0x1F)
    }

    private mutating func mix(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* 0x0000_0100_0000_01B3
    }

    var hex: String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
