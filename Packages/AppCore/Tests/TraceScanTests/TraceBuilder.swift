// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds synthetic dev trace files for the scanner tests (PLT-R904A): sample words typed through the real engine,
// so their engine lines are exactly what the app would record, plus boundaries, jobs, readbacks and markers. Times
// advance in milliseconds from a fixed instant; files are named by UTC hour (the tests read them in UTC).

import Foundation
import VietnameseEngine

@testable import TraceScanCore

struct TraceBuilder {
    static let utc = TimeZone(secondsFromGMT: 0) ?? .current
    /// 2026-11-14 09:00:00 UTC in microseconds.
    static let base: Int64 = 1_794_646_800_000_000
    static let settings: [String: String] = [
        "typingMethod": "telex", "tonePlacement": "traditional", "englishRestore": "true",
        "telexStandaloneW": "true", "telexBracketKeys": "false", "keepAsTypedCount": "0",
        "keepVietnameseCount": "0",
    ]
    static let editor = "com.example.editor"

    private(set) var lines: [[String: Any]] = []
    private(set) var t: Int64
    private var session: Session
    private let engine: Engine

    init(start: Int64 = TraceBuilder.base, configuration: EngineConfiguration = EngineConfiguration()) {
        t = start
        engine = Engine(configuration: configuration, resources: TraceBuilder.resources)
        session = Session(engine: engine)
    }

    /// The bundled lexicons, loaded once for every builder.
    static let resources: Resources = (try? ReplayEngineFactory.bundledResources()) ?? .empty

    // MARK: Lines

    mutating func line(_ type: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["type"] = type
        line["t"] = t
        lines.append(line)
    }

    mutating func advance(_ milliseconds: Int64) { t += milliseconds * 1_000 }

    /// File header, launch, settings and focus, as a fresh launch writes them.
    mutating func launch(bundle: String = TraceBuilder.editor, rule: String? = "editor.sample") {
        line("file", ["v": 1, "launch": "abc1", "app": "0.1.0 (1)"])
        line("start", ["launch": "abc1", "app": "0.1.0 (1)"])
        line("settings", ["s": TraceBuilder.settings])
        focus(bundle: bundle, rule: rule)
    }

    mutating func focus(bundle: String, rule: String?, requireTextFocus: String = "whenKnown") {
        var fields: [String: Any] = [
            "gen": 1, "bundle": bundle, "role": "AXTextArea", "strat": "backspaceReplace", "rtf": requireTextFocus,
            "ax": "available", "secure": false, "mode": "vietnamese", "modeSrc": "globalMode", "ctx": "general",
            "er": true, "mac": true,
        ]
        if let rule { fields["rule"] = rule }
        line("focus", fields)
    }

    /// Types `text` key by key through the engine (ANSI letters only; key codes do not matter for the scanner
    /// except Backspace, Return and Tab), 120 ms apart.
    mutating func type(_ text: String) {
        for character in text {
            press(String(character), event: .key(KeyInput(character)))
            advance(120)
        }
    }

    mutating func backspace() {
        press(nil, keyCode: 0x33, event: .backspace)
        advance(120)
    }

    /// A key line and the engine line of the same instant; `engineLine` false for keys the engine never saw.
    mutating func press(
        _ character: String?, keyCode: UInt16 = 0, flags: UInt64 = 0, outcome: String? = nil,
        event: EngineEvent? = nil
    ) {
        var output: EngineOutput?
        if let event { output = session.handle(event) }
        var key: [String: Any] = ["ev": "keyDown", "kc": Int(keyCode), "fl": flags]
        if let character { key["ch"] = character }
        key["out"] = outcome ?? Self.outcome(of: output)
        line("key", key)
        if let output { engineLine(output) }
        var up = key
        up["ev"] = "keyUp"
        up["out"] = "passed"
        advance(30)
        line("key", up)
        advance(-30)
    }

    mutating func engineLine(_ output: EngineOutput, tamperedInsert: String? = nil) {
        var fields: [String: Any] = ["comp": output.composingText]
        switch output.action {
        case .passThrough: fields["act"] = "passThrough"
        case .edit(let edit, let thenPassThrough):
            fields["act"] = thenPassThrough ? "editThenPassThrough" : "edit"
            fields["del"] = edit.deleteCount
            fields["ins"] = tamperedInsert ?? edit.insert
        }
        if let decision = output.decision { fields["dec"] = Self.plainName(decision) }
        line("engine", fields)
    }

    /// A boundary: the host resets the engine.
    mutating func boundary(_ reason: String, job: String? = nil) {
        _ = session.handle(.reset(.unknown))
        var fields: [String: Any] = ["reason": reason]
        if let job { fields["job"] = job }
        line("boundary", fields)
    }

    mutating func readback(_ text: String, reason: String = "commit") {
        line("readback", ["reason": reason, "status": "ok", "text": text, "selLoc": text.utf16.count, "selLen": 0])
    }

    mutating func job(
        _ sequence: Int, kind: String = "compose", outcome: String = "executed", totalUs: Int = 4_000
    ) {
        line(
            "job",
            [
                "seq": sequence, "gen": 1, "kind": kind, "strat": "backspaceReplace", "out": outcome, "delN": 1,
                "insN": 1, "posted": 4, "totalUs": totalUs, "runUs": totalUs / 2,
            ])
    }

    mutating func marker(_ source: String = "chord") { line("marker", ["src": source]) }

    /// The engine's own output for `event` without a key line (a test then writes a doctored line).
    mutating func engineOutput(_ event: EngineEvent) -> EngineOutput { session.handle(event) }

    /// The recorder writes enum names without module and type qualifiers: `kept(unchanged)`.
    static func plainName(_ value: some Sendable) -> String {
        String(describing: value).replacingOccurrences(of: #"[A-Za-z_]+\."#, with: "", options: .regularExpression)
    }

    private static func outcome(of output: EngineOutput?) -> String {
        guard let output else { return "passed" }
        if case .edit(_, let thenPassThrough) = output.action { return thenPassThrough ? "held" : "consumedForEdit" }
        return "passed"
    }

    // MARK: Files

    var data: Data {
        var data = Data()
        for line in lines {
            if let encoded = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                data.append(encoded)
                data.append(0x0A)
            }
        }
        return data
    }

    /// Writes the lines into `directory`, one file per UTC hour of their times.
    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var byHour: [String: [[String: Any]]] = [:]
        for line in lines {
            let micros = line["t"] as? Int64 ?? 0
            byHour[Self.hourKey(micros), default: []].append(line)
        }
        for (hour, hourLines) in byHour {
            var data = Data()
            for line in hourLines {
                data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: directory.appendingPathComponent(hour + ".jsonl"))
        }
    }

    static func hourKey(_ micros: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour], from: Date(timeIntervalSince1970: Double(micros) / 1_000_000))
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return pad(parts.year, 4) + pad(parts.month, 2) + pad(parts.day, 2) + "-" + pad(parts.hour, 2)
    }

    /// Events as the store would produce them (time order, ties in writing order), without files.
    var events: [TraceEvent] {
        let decoder = JSONDecoder()
        let decoded = lines.compactMap { line -> TraceLine? in
            guard let data = try? JSONSerialization.data(withJSONObject: line) else { return nil }
            return try? decoder.decode(TraceLine.self, from: data)
        }
        let ordered = decoded.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
        return ordered.enumerated().map { index, item in TraceEvent(index: index, line: item.element, file: "test") }
    }

    /// A fresh temporary folder for one test.
    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("trace-scan-tests-" + UUID().uuidString)
    }
}
