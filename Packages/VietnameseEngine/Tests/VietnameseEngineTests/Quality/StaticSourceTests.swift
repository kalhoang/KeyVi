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

@Suite("Static checks of the core sources (REG-23)")
struct StaticSourceTests {
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
