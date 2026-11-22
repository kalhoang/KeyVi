// SPDX-License-Identifier: MPL-2.0
//
// Measurement harness of rule L4 and the `w` doubling (spec/01-engine.md ENG-R804, REG-40, REG-41). No target of this
// repository compiles this file: prepare-tree.sh copies it into Tests/VietnameseEngineDataTests/RealData/ of a scratch
// export of the package, and run-tree.sh runs it there (README.md in this directory).
//
// Types each line of $WDM_INPUT (KeyNotation: `⌫` Backspace, `⎋` the restore key) from an empty field with the bundled
// data, Telex defaults and typoCorrection on when $WDM_CORRECTION is 1, off otherwise, and writes one line per input to
// $WDM_OUTPUT: a flag (1 when some state showed the escaped `w` of a standalone `w` doubling right after a capital `W`,
// the case REG-41 changes), a tab and the final field; with $WDM_TRACE=1 also a tab and the field after every event,
// separated by U+001F. A newline or tab in a field is written as `\n` or `\t`. Without $WDM_INPUT the test does nothing.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("w doubling measurement")
struct WDoublingMeasureTests {
    @Test func typesEveryInputLine() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["WDM_INPUT"], let output = environment["WDM_OUTPUT"] else { return }
        let configuration = EngineConfiguration(typoCorrection: environment["WDM_CORRECTION"] == "1")
        let trace = environment["WDM_TRACE"] == "1"
        let engine = Engine(configuration: configuration, resources: try RealData.resources())
        let lines = try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n")
        var result = ""
        result.reserveCapacity(lines.count * 32)
        for line in lines {
            result += try Self.row(typing: String(line), engine: engine, trace: trace)
        }
        try result.write(toFile: output, atomically: true, encoding: .utf8)
    }

    /// One output line for one input line: the flag, the final field and, with `trace`, the field after every event.
    private static func row(typing keys: String, engine: Engine, trace: Bool) throws -> String {
        var driver = EngineDriver(engine: engine)
        var fields: [String] = []
        var flagged = false
        for event in KeyNotation.events(keys) {
            _ = try driver.send(event)
            if trace { fields.append(driver.field.string) }
            if let composition = driver.state.active?.composition, showsEscapedWAfterCapital(composition) {
                flagged = true
            }
        }
        var row = (flagged ? "1" : "0") + "\t" + escaped(driver.field.string)
        if trace { row += "\t" + fields.map(escaped).joined(separator: "\u{1F}") }
        return row + "\n"
    }

    /// The literal tail starts with the escaping `w` of a standalone `w` doubling, typed in lowercase right after a
    /// capital `W` (ENG-R903 as amended on 22/11/2026).
    private static func showsEscapedWAfterCapital(_ composition: Composition) -> Bool {
        guard let start = composition.literalStart, start > 0, composition.standaloneWDoublings.contains(start) else {
            return false
        }
        return ASCII.isUppercaseLetter(composition.raw[start - 1]) && !ASCII.isUppercaseLetter(composition.raw[start])
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }
}
