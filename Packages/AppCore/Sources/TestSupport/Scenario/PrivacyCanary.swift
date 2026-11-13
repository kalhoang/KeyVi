// SPDX-License-Identifier: GPL-3.0-or-later
//
// Privacy canary (02-platform.md section 9 acceptance, 13.1, PLT-R901, PLT-R904): the `testhost.privacyCanary.*`
// scenarios type canary words through every injection strategy (profile `privacy-canary`); afterwards no file the
// app wrote outside `captures/` (PLT-R905) and no unified-log output of the app process may contain a canary, in
// any encoding a writer could use. `compat-harness run` scans automatically after a run that included a canary
// scenario; the evidence (file list, log text) comes from `PrivacyEvidenceSource` (live: CompatHarness/Live).

public import AppModel
public import Foundation

public enum PrivacyCanary {
    /// Scenario id prefix of the canary scenarios.
    public static let scenarioPrefix = "testhost.privacyCanary."

    /// One canary: the key script (ABC positions, one letter per key) and every text the app shows for it that
    /// contains its unique tail. ScenarioOracleTests derives the texts from the engine and keeps this list exact.
    public struct Canary: Sendable, Hashable {
        public var keys: String
        public var texts: [String]
    }

    public static let canaries: [Canary] = [
        Canary(keys: "kanaryzqx", texts: ["kanaryzqx", "kẩnyz", "kẩnyzq", "kẩnyzqx"])
    ]

    /// Every string whose presence is a leak: key scripts and texts.
    public static var tokens: [String] {
        var seen = Set<String>()
        return canaries.flatMap { [$0.keys] + $0.texts }.filter { seen.insert($0).inserted }
    }

    public static func isCanaryScenario(_ id: String) -> Bool { id.hasPrefix(scenarioPrefix) }

    /// Byte patterns of `token`: NFC and NFD, UTF-8 and UTF-16 (both orders, as in binary property lists), upper
    /// case, and the JSON `\uXXXX` escape of non-ASCII characters.
    public static func patterns(for token: String) -> [(encoding: String, bytes: Data)] {
        var patterns: [(String, Data)] = []
        let forms = [
            ("nfc", token.precomposedStringWithCanonicalMapping), ("nfd", token.decomposedStringWithCanonicalMapping),
        ]
        for (form, text) in forms {
            for (suffix, variant) in [("", text), ("-upper", text.uppercased())] {
                patterns.append(("utf8-" + form + suffix, Data(variant.utf8)))
                patterns.append(("utf16le-" + form + suffix, variant.data(using: .utf16LittleEndian) ?? Data()))
                patterns.append(("utf16be-" + form + suffix, variant.data(using: .utf16BigEndian) ?? Data()))
                patterns.append(("json-escaped-" + form + suffix, Data(jsonEscaped(variant).utf8)))
            }
        }
        var seen = Set<Data>()
        return patterns.filter { !$0.1.isEmpty && seen.insert($0.1).inserted }
    }

    static func jsonEscaped(_ text: String) -> String {
        text.utf16.map { unit in
            unit < 0x80 ? String(UnicodeScalar(UInt8(unit))) : String(format: "\\u%04x", unit)
        }.joined()
    }
}

/// Where a canary was found. `token` is canary fixture text, never something a person typed.
public struct PrivacyFinding: Sendable, Hashable, Codable {
    public var location: String
    public var token: String
    public var encoding: String
}

public struct PrivacyReport: Sendable, Hashable, Codable {
    public var scannedFiles: Int
    public var scannedLogBytes: Int
    /// Files that could not be read completely (too large or unreadable): a failure, since they were not checked.
    public var unreadable: [String]
    /// Files listed but gone when they were read (a settings backup the app pruned meanwhile, PLT-R1005). They left
    /// nothing on disk to leak, so they do not fail the scan; the harness quits the app first, so normally none.
    public var vanished: [String]
    public var findings: [PrivacyFinding]
    public var passed: Bool { findings.isEmpty && unreadable.isEmpty }
}

/// What the app under test wrote. Runner only (CompatHarness/Live): file enumeration and `log show`.
public protocol PrivacyEvidenceSource: Sendable {
    /// Every regular file the app may have written (Application Support and Logs folders, preferences, caches,
    /// saved state), excluding `Logs/<folder>/captures/` (PLT-R905).
    func appWrittenFiles() throws -> [URL]
    /// Unified-log output of the app process since this source was created, every level, as text.
    func unifiedLog() async throws -> String
}

public struct PrivacyScanner: Sendable {
    /// Largest file read; logs rotate at 1 MB (PLT-R903), settings at most 5 MB (PLT-R912).
    public static let maximumFileBytes = 32 << 20
    private let patterns: [(token: String, encoding: String, bytes: Data)]

    public init(tokens: [String] = PrivacyCanary.tokens) {
        patterns = tokens.flatMap { token in
            PrivacyCanary.patterns(for: token).map { (token, $0.encoding, $0.bytes) }
        }
    }

    /// First match per token in `data`.
    public func findings(in data: Data, location: String) -> [PrivacyFinding] {
        var found = Set<String>()
        var findings: [PrivacyFinding] = []
        for pattern in patterns where !found.contains(pattern.token) && data.range(of: pattern.bytes) != nil {
            found.insert(pattern.token)
            findings.append(PrivacyFinding(location: location, token: pattern.token, encoding: pattern.encoding))
        }
        return findings
    }

    public func scan(files: [URL], fileSystem: any FileSystem, log: String) -> PrivacyReport {
        var findings: [PrivacyFinding] = []
        var unreadable: [String] = []
        var vanished: [String] = []
        for file in files {
            guard let data = try? fileSystem.readData(at: file, maxBytes: Self.maximumFileBytes) else {
                if fileSystem.fileExists(at: file) { unreadable.append(file.path) } else { vanished.append(file.path) }
                continue
            }
            findings += self.findings(in: data, location: file.path)
        }
        let logData = Data(log.utf8)
        findings += self.findings(in: logData, location: "unified log")
        return PrivacyReport(
            scannedFiles: files.count - unreadable.count - vanished.count, scannedLogBytes: logData.count,
            unreadable: unreadable, vanished: vanished, findings: findings)
    }
}
