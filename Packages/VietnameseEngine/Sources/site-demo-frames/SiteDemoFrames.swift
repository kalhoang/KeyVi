// SPDX-License-Identifier: MPL-2.0
//
// site-demo-frames: types the website's demo sentences (site/demo/script.json) through the real engine and writes
// site/demo/frames.json (PRD-R73; website redesign design of 16/11/2026, section 7.4). With --check it writes
// nothing and fails when the committed file differs from what this engine produces (CI and the local gate).

import Foundation
import VietnameseEngine
import VietnameseEngineData

enum SiteDemoFrames {
    static let usage = """
        usage: site-demo-frames [--check] [--script PATH] [--out PATH]

        Types every demo of the script through the engine and writes the frames file. Run it from the
        repository root: swift run --package-path Packages/VietnameseEngine site-demo-frames

        options:
          --check        write nothing; fail when the frames file differs from what this engine produces
          --script PATH  the demo script (default: \(defaultScript))
          --out PATH     the frames file (default: \(defaultOutput))

        exit codes: 0 success; 1 a demo's text differs from its expect, or --check found a stale file;
        2 bad arguments, or an unreadable or invalid script
        """

    static let defaultScript = "site/demo/script.json"
    static let defaultOutput = "site/demo/frames.json"

    /// Runs the tool; `arguments` exclude the program name. Relative paths resolve from `currentDirectory`.
    /// Problems go to `log`, the success line to `output`. Returns the exit code.
    static func run(
        arguments: [String], currentDirectory: URL, log: (String) -> Void = SiteDemoFrames.standardError,
        output: (String) -> Void = { print($0) }
    ) -> Int32 {
        let options: Options
        do {
            options = try Options(arguments)
        } catch {
            log("site-demo-frames: \(error)\n\(usage)")
            return 2
        }
        if options.help {
            output(usage)
            return 0
        }
        let script: DemoScript
        do {
            script = try DemoScript.load(from: resolve(options.script, in: currentDirectory))
        } catch {
            log("site-demo-frames: \(error)")
            return 2
        }
        let demos: [RecordedDemo]
        do {
            demos = try record(script)
        } catch {
            log("site-demo-frames: \(error)")
            return 1
        }
        let mismatches = zip(script.demos, demos).filter { $0.expect != $1.text }
        for (demo, recorded) in mismatches {
            log(
                "site-demo-frames: \(demo.id): expected \(String(reflecting: demo.expect)), the engine gives "
                    + "\(String(reflecting: recorded.text)); change the sentence, never the frames")
        }
        guard mismatches.isEmpty else { return 1 }
        let data = renderFramesFile(demos)
        let target = resolve(options.output, in: currentDirectory)
        return options.check
            ? check(data, against: target, named: options.output, log: log)
            : write(data, to: target, named: options.output, count: demos.count, log: log, output: output)
    }

    /// Records every demo of `script` with the bundled resources, loaded once (no user lists, no macros).
    static func record(_ script: DemoScript) throws -> [RecordedDemo] {
        let resources = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        let recorder = FrameRecorder(resources: resources)
        return try script.demos.map(recorder.record)
    }

    static func standardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func resolve(_ path: String, in directory: URL) -> URL {
        URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    private static func check(_ data: Data, against url: URL, named name: String, log: (String) -> Void) -> Int32 {
        guard let committed = try? Data(contentsOf: url) else {
            log("site-demo-frames: \(name) is missing; run site-demo-frames and commit the file")
            return 1
        }
        guard committed == data else {
            log(
                "site-demo-frames: \(name) differs from what this engine produces; run "
                    + "`swift run --package-path Packages/VietnameseEngine site-demo-frames` from the repository root "
                    + "and commit the file with the engine change")
            return 1
        }
        return 0
    }

    private static func write(
        _ data: Data, to url: URL, named name: String, count: Int, log: (String) -> Void, output: (String) -> Void
    ) -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log("site-demo-frames: cannot write \(name): \(error)")
            return 1
        }
        output("wrote \(name) (\(count) demos)")
        return 0
    }
}

/// The command line: `[--check] [--script PATH] [--out PATH]` or `--help`.
struct Options {
    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    let check: Bool
    let help: Bool
    let script: String
    let output: String

    init(_ arguments: [String]) throws {
        var check = false
        var help = false
        var values: [String: String] = [:]
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--check": check = true
            case "--help", "-h": help = true
            case "--script", "--out":
                guard let value = remaining.popFirst(), !value.hasPrefix("--") else {
                    throw UsageError(description: "\(argument) needs a path")
                }
                values[argument] = value
            default: throw UsageError(description: "unknown argument '\(argument)'")
            }
        }
        self.check = check
        self.help = help
        self.script = values["--script"] ?? SiteDemoFrames.defaultScript
        self.output = values["--out"] ?? SiteDemoFrames.defaultOutput
    }
}

// MARK: - The frames file

/// The frames file, schema version 1: sorted keys, two-space indentation, `/` not escaped, absent keys omitted and a
/// final newline. Written by hand rather than with JSONEncoder so that the bytes are the same on macOS and on Linux,
/// where CI runs the check.
func renderFramesFile(_ demos: [RecordedDemo]) -> Data {
    let root = JSONValue.object([
        "schemaVersion": .number(DemoScript.supportedSchemaVersion),
        "generator": .string("site-demo-frames"),
        "demos": .object(Dictionary(demos.map { ($0.id, $0.json) }, uniquingKeysWith: { first, _ in first })),
    ])
    return Data((root.rendered(indent: "") + "\n").utf8)
}

extension RecordedDemo {
    var json: JSONValue {
        .object([
            "keys": .string(keys), "method": .string(method.rawValue), "toneStyle": .string(toneStyle.rawValue),
            "text": .string(text), "frames": .array(frames.map(\.json)),
        ])
    }
}

extension RecordedDemo.Frame {
    var json: JSONValue {
        let members: [(String, JSONValue)?] = [
            ("key", .string(key)), ("text", .string(text)), commit.map { ("commit", $0.json) },
            revision ? ("revision", .bool(true)) : nil, toggle ? ("toggle", .bool(true)) : nil,
        ]
        return .object(Dictionary(uniqueKeysWithValues: members.compactMap { $0 }))
    }
}

extension RecordedDemo.Commit {
    var json: JSONValue {
        let members: [(String, JSONValue)?] = [
            ("raw", .string(raw)), ("text", .string(text)), ("outcome", .string(outcome)),
            rule.map { ("rule", .string($0)) }, ("english", .bool(english)),
        ]
        return .object(Dictionary(uniqueKeysWithValues: members.compactMap { $0 }))
    }
}

/// The JSON values the frames file needs.
enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value pretty printed; nested lines start with `indent` plus two spaces per level.
    func rendered(indent: String) -> String {
        let inner = indent + "  "
        switch self {
        case .string(let text): return Self.quoted(text)
        case .number(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let lines = items.map { inner + $0.rendered(indent: inner) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let sorted = members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            let lines = sorted.map { inner + Self.quoted($0.key) + ": " + $0.value.rendered(indent: inner) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// A JSON string literal: quotes, backslashes and control characters escaped, everything else (including `/`
    /// and non-ASCII letters) written as is.
    static func quoted(_ text: String) -> String {
        let escaped = text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\"": return "\\\""
            case "\\": return "\\\\"
            case "\n": return "\\n"
            case "\r": return "\\r"
            case "\t": return "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                return "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: return String(scalar)
            }
        }
        return "\"" + escaped.joined() + "\""
    }
}
