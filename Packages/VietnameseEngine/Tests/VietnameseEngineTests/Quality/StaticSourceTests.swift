// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

/// A static scan of Swift source for what the engine core must never contain (REG-23): imports
/// (ENG-R1201: standard library only, so no Foundation, Darwin, Glibc or os), logging and I/O
/// (ENG-R128, ENG-R1220), clocks, randomness, the environment and the locale (ENG-R1210, ENG-R905), and
/// mutable global or static state (ENG-R1202). Comments and string literals are blanked before the scan,
/// so documentation may name these symbols.
enum CoreSourceScanner {
    struct Finding: Hashable, CustomStringConvertible {
        let file: String
        let line: Int
        let rule: String
        let symbol: String
        var description: String { "\(file):\(line): \(symbol) (\(rule))" }
    }

    /// Identifiers that perform I/O or logging, read a clock, randomness, the environment or the locale,
    /// or schedule work.
    static let forbiddenIdentifiers: [String: String] = {
        var table: [String: String] = [:]
        for name in [
            "print", "debugPrint", "dump", "NSLog", "os_log", "os_signpost", "Logger", "OSLog", "FileManager",
            "FileHandle", "fopen", "fclose", "fread", "fwrite", "fputs", "fprintf", "printf", "puts", "fflush",
            "stdout", "stderr", "URL", "URLSession", "URLRequest", "Socket", "UserDefaults", "NotificationCenter",
            "dlopen", "syscall",
        ] {
            table[name] = "ENG-R128, ENG-R1220: no logging or I/O"
        }
        for name in [
            "Date", "ContinuousClock", "SuspendingClock", "clock_gettime", "mach_absolute_time",
            "SystemRandomNumberGenerator", "random", "randomElement", "shuffled", "shuffle", "getenv", "setenv",
            "ProcessInfo", "CommandLine", "Locale", "TimeZone", "Calendar", "DispatchQueue", "Thread", "exit",
            "abort",
        ] {
            table[name] = "ENG-R1210: no clock, randomness, environment, locale or side effects"
        }
        return table
    }()

    /// Every finding in `source`.
    static func scan(_ source: String, file: String) -> [Finding] {
        let code = blankCommentsAndStrings(source)
        var findings: [Finding] = []
        for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            let tokens = identifiers(in: line)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let first = tokens.first, first.name == "import" || trimmed.hasPrefix("@_exported") {
                let module = tokens.dropFirst().first?.name ?? ""
                findings.append(
                    Finding(
                        file: file, line: number, rule: "ENG-R1201: standard library only", symbol: "import \(module)"))
            }
            for (index, token) in tokens.enumerated() {
                if let rule = forbiddenIdentifiers[token.name] {
                    findings.append(Finding(file: file, line: number, rule: rule, symbol: token.name))
                }
                // `open(` as a call (POSIX open); `reopened(` is a different identifier.
                if token.name == "open", token.followedByParenthesis {
                    findings.append(Finding(file: file, line: number, rule: "ENG-R128: no I/O", symbol: "open("))
                }
                let next = index + 1 < tokens.count ? tokens[index + 1].name : ""
                if (token.name == "static" || token.name == "class") && next == "var" {
                    findings.append(
                        Finding(
                            file: file, line: number, rule: "ENG-R1202: no mutable static state",
                            symbol: "\(token.name) var"))
                }
            }
            if line.contains("nonisolated(unsafe)") || line.contains("@unchecked") {
                findings.append(
                    Finding(file: file, line: number, rule: "ENG-R1202, ENG-R1203", symbol: "unchecked concurrency"))
            }
            // A `var` at the start of a line outside any declaration is a mutable global.
            if line.hasPrefix("var ") || line.hasPrefix("public var ") || line.hasPrefix("package var ") {
                findings.append(
                    Finding(file: file, line: number, rule: "ENG-R1202: no mutable global state", symbol: "global var"))
            }
        }
        return findings
    }

    struct Token {
        let name: String
        let followedByParenthesis: Bool
    }

    static func identifiers(in line: Substring) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character.isLetter || character == "_" else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_"
            {
                end += 1
            }
            var after = end
            while after < characters.count, characters[after] == " " { after += 1 }
            let preceded = index > 0 && (characters[index - 1] == "#" || characters[index - 1] == "@")
            if !preceded {
                tokens.append(
                    Token(
                        name: String(characters[index..<end]),
                        followedByParenthesis: after < characters.count && characters[after] == "("))
            }
            index = end
        }
        return tokens
    }

    /// `source` with comments and string literals (plain, multi-line and raw) replaced by spaces; line
    /// breaks are kept so line numbers stay right.
    static func blankCommentsAndStrings(_ source: String) -> String {
        let characters = Array(source)
        var result: [Character] = []
        result.reserveCapacity(characters.count)
        var index = 0
        func blank(_ character: Character) { result.append(character == "\n" ? "\n" : " ") }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if character == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" {
                    blank(characters[index])
                    index += 1
                }
            } else if character == "/", next == "*" {
                var depth = 0
                repeat {
                    if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                        depth += 1
                        blank("/")
                        blank("*")
                        index += 2
                    } else if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                        depth -= 1
                        blank("*")
                        blank("/")
                        index += 2
                    } else {
                        blank(characters[index])
                        index += 1
                    }
                } while depth > 0 && index < characters.count
            } else if character == "\"" || (character == "#" && next == "\"") {
                index = skipString(characters, from: index, into: &result)
            } else {
                result.append(character)
                index += 1
            }
        }
        return String(result)
    }

    /// Skips a string literal starting at `start` (`"`, `"""`, or raw `#"` / `#"""`), blanking it.
    private static func skipString(_ characters: [Character], from start: Int, into result: inout [Character]) -> Int {
        var index = start
        var hashes = 0
        while index < characters.count, characters[index] == "#" {
            hashes += 1
            index += 1
        }
        let multiline =
            index + 2 < characters.count && characters[index] == "\"" && characters[index + 1] == "\""
            && characters[index + 2] == "\""
        let quotes = multiline ? 3 : 1
        index += quotes
        let closing = Array(repeating: Character("\""), count: quotes) + Array(repeating: Character("#"), count: hashes)
        while index < characters.count {
            if hashes == 0, characters[index] == "\\" {
                index += 2
                continue
            }
            if index + closing.count <= characters.count, Array(characters[index..<index + closing.count]) == closing {
                index += closing.count
                break
            }
            if !multiline, characters[index] == "\n" { break }
            index += 1
        }
        for character in characters[start..<min(index, characters.count)] {
            result.append(character == "\n" ? "\n" : " ")
        }
        return index
    }

    /// The core target's sources: `Sources/VietnameseEngine/**/*.swift`.
    static func coreSources() throws -> [(name: String, text: String)] {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VietnameseEngine")
        let names = (FileManager.default.enumerator(atPath: core.path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try String(contentsOf: core.appendingPathComponent($0), encoding: .utf8)) }
    }
}

/// ENG-R1119, ENG-T54: every engine configuration built by the tests, the corpora, the benchmark and the demo frames
/// names the typo correction switch, so the 1.0 suites hold the 1.0 behaviour with it off and only the suites of
/// section 11A run with it on (the default of 12.2 is on). The one exemption is the test that asserts the defaults.
enum ConfigurationCallScanner {
    /// Directories of the package scanned, relative to its root (`Sources/lexicon-builder` since the review of the
    /// API stage of 1.1.0).
    static let directories = [
        "Sources/VietnameseEngineTesting", "Sources/site-demo-frames", "Benchmarks", "Tests", "Sources/lexicon-builder",
    ]

    struct Call: Hashable, CustomStringConvertible {
        let file: String
        let line: Int
        let arguments: String
        var description: String { "\(file):\(line): EngineConfiguration(\(arguments))" }
    }

    /// Every `EngineConfiguration(...)` call in `source` with its balanced argument text; comments and strings are
    /// blanked first, so documentation may name the type.
    static func calls(in source: String, file: String) -> [Call] {
        let code = Array(CoreSourceScanner.blankCommentsAndStrings(source))
        let name = Array("EngineConfiguration")
        var calls: [Call] = []
        var index = 0
        var line = 1
        while index < code.count {
            if code[index] == "\n" { line += 1 }
            guard code[index] == "E", index + name.count < code.count, Array(code[index..<index + name.count]) == name,
                index == 0 || !(code[index - 1].isLetter || code[index - 1].isNumber || code[index - 1] == "_")
            else {
                index += 1
                continue
            }
            var open = index + name.count
            while open < code.count, code[open] == " " { open += 1 }
            guard open < code.count, code[open] == "(" else {
                index += name.count
                continue
            }
            var depth = 0
            var close = open
            repeat {
                if code[close] == "(" { depth += 1 } else if code[close] == ")" { depth -= 1 }
                close += 1
            } while depth > 0 && close < code.count
            let arguments = String(code[(open + 1)..<max(open + 1, close - 1)])
            calls.append(Call(file: file, line: line, arguments: arguments))
            line += arguments.filter { $0 == "\n" }.count
            index = close
        }
        return calls
    }

    /// The calls of `source` that do not name `typoCorrection:`, except inside `func defaults()` of
    /// PublicAPITests.swift, the test of the 12.2 defaults.
    static func violations(in source: String, file: String) -> [Call] {
        let exempt = file.hasSuffix("Quality/PublicAPITests.swift") ? lines(ofFunction: "defaults", in: source) : nil
        return calls(in: source, file: file).filter { call in
            !call.arguments.contains("typoCorrection:") && !(exempt?.contains(call.line) ?? false)
        }
    }

    /// The line range of the body of `func <name>()` in `source`, nil when absent.
    static func lines(ofFunction name: String, in source: String) -> ClosedRange<Int>? {
        let code = Array(CoreSourceScanner.blankCommentsAndStrings(source))
        let text = String(code)
        guard let start = text.range(of: "func \(name)()") else { return nil }
        var index = text.distance(from: text.startIndex, to: start.lowerBound)
        let firstLine = code[..<index].filter { $0 == "\n" }.count + 1
        while index < code.count, code[index] != "{" { index += 1 }
        var depth = 0
        repeat {
            if code[index] == "{" { depth += 1 } else if code[index] == "}" { depth -= 1 }
            index += 1
        } while depth > 0 && index < code.count
        return firstLine...(code[..<index].filter { $0 == "\n" }.count + 1)
    }

    /// The Swift files of the scanned directories, relative to the package root.
    static func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var files: [(String, String)] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            let names = (FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(".swift") }.sorted()
            for name in names {
                files.append(
                    ("\(directory)/\(name)", try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8))
                )
            }
        }
        return files
    }
}

@Suite("Static checks of the core sources (REG-23)")
struct StaticSourceTests {
    @Test("ENG-R1119: every configuration outside the core names the typo correction switch")
    func everyConfigurationOutsideTheCoreNamesTheSwitch() throws {
        let sources = try ConfigurationCallScanner.sources()
        let calls = sources.flatMap { ConfigurationCallScanner.calls(in: $0.text, file: $0.name) }
        #expect(calls.count >= 150)  // the sweep of the API stage covered about 190 calls
        for (name, text) in sources {
            for call in ConfigurationCallScanner.violations(in: text, file: name) {
                Issue.record("\(call)")
            }
        }
    }

    @Test("The configuration scanner finds calls without the switch and ignores comments, strings and types")
    func configurationScannerHasTeeth() {
        let source = """
            // EngineConfiguration() in a comment
            let a = EngineConfiguration()
            let b = EngineConfiguration(appContext: .code, typoCorrection: false)
            let c: EngineConfiguration = EngineConfiguration(
                inputMethod: .vni,
                toneStyle: .modern)
            let d = "EngineConfiguration(appContext: .code)"
            let e = [EngineConfiguration: Int]()
            let f = VietnameseEngine.EngineConfiguration(typoCorrection: true)
            let g = MyEngineConfiguration()
            """
        let calls = ConfigurationCallScanner.calls(in: source, file: "x.swift")
        #expect(calls.map(\.line) == [2, 3, 4, 9])
        #expect(ConfigurationCallScanner.violations(in: source, file: "x.swift").map(\.line) == [2, 4])
        let exempted = """
            struct PublicAPITests {
                func defaults() {
                    let configuration = EngineConfiguration()
                    _ = EngineConfiguration(historyLimit: 0)
                }
                func other() { _ = EngineConfiguration() }
            }
            """
        let violations = ConfigurationCallScanner.violations(in: exempted, file: "Tests/Quality/PublicAPITests.swift")
        #expect(violations.map(\.line) == [6])
        // The lexicon builder is scanned too, with no file exempted (`EngineTyper` names the switch since 1.1.0).
        #expect(ConfigurationCallScanner.directories.contains("Sources/lexicon-builder"))
        #expect(ConfigurationCallScanner.violations(in: source, file: "Sources/lexicon-builder/Build.swift").count == 2)
    }

    @Test("The core imports nothing and has no logging, I/O, clock, randomness or mutable global state")
    func coreIsClean() throws {
        let sources = try CoreSourceScanner.coreSources()
        #expect(sources.count >= 30)
        for (name, text) in sources {
            for finding in CoreSourceScanner.scan(text, file: name) {
                Issue.record("\(finding)")
            }
        }
    }

    @Test("The scanner finds every forbidden pattern and ignores comments and strings")
    func scannerHasTeeth() {
        let bad = """
            import Foundation
            import Darwin
            @_exported import Glibc
            var counter = 0
            struct S {
                static var shared = 1
                nonisolated(unsafe) static let x = 2
                func f() {
                    print("x")
                    let handle = fopen("/tmp/x", "w")
                    _ = open ("/tmp/y", 0)
                    os_log("x")
                    let logger = Logger()
                    _ = FileManager.default
                    _ = URLSession.shared
                    _ = ContinuousClock.now
                    _ = Int.random(in: 0..<2)
                    _ = ProcessInfo.processInfo.environment
                }
            }
            """
        let symbols = Set(CoreSourceScanner.scan(bad, file: "bad.swift").map(\.symbol))
        for expected in [
            "import Foundation", "import Darwin", "import Glibc", "global var", "static var", "unchecked concurrency",
            "print", "fopen", "open(", "os_log", "Logger", "FileManager", "URLSession", "ContinuousClock", "random",
            "ProcessInfo",
        ] {
            #expect(symbols.contains(expected), "\(expected) not found")
        }
        let clean = """
            /// Never call print(...) or import Foundation here; FileManager is for the host.
            /* nested /* print("x") */ fopen */
            let text = "import Foundation; print(1); static var"
            let raw = #"os_log("\\(x)")"#
            let multi = \"\"\"
                URLSession and Logger()
                \"\"\"
            func reopened(display: Int) -> Int { display }
            """
        #expect(CoreSourceScanner.scan(clean, file: "clean.swift").isEmpty)
    }
}
