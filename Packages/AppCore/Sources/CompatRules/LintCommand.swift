// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `compat-lint` command (02-platform.md 13.1 "Rules"): reads the rules file, the matrix and the scenario
// folder, runs `RulesLinter` and renders findings. It lives in the library so it is unit tested; the executable
// only forwards arguments and writes the output. Hosted CI runs it on every pull request.

public import AppModel
public import Foundation

public enum CompatLintCommand {
    public struct Outcome: Sendable, Hashable {
        public var output: String
        public var exitCode: Int32

        public init(output: String, exitCode: Int32) {
            self.output = output
            self.exitCode = exitCode
        }
    }

    public static let exitClean: Int32 = 0
    public static let exitFindings: Int32 = 1
    public static let exitUsage: Int32 = 2
    static let maximumFileBytes = 5_000_000

    public static let usage = """
        Usage: compat-lint [--rules FILE] [--matrix FILE] [--scenarios DIR] [--release] [--today YYYY-MM-DD]

        Checks compat/rules.json and compat/matrix.json (PLT-R503 to PLT-R531, QA-R17).
          --rules FILE      rules file (default compat/rules.json)
          --matrix FILE     verification matrix (default compat/matrix.json; if missing, manual rules warn)
          --scenarios DIR   scenario folder with one <id>.json per scenario (default compat/scenarios)
          --release         release gate: VERIFY items, overdue reviewBy and stale Tier 1 rows are errors
          --today DATE      override today's date (tests)
        Exit status: 0 clean (warnings allowed), 1 errors, 2 usage error or unreadable rules file.

        """

    public static func run(
        arguments: [String], environment: [String: String], fileSystem: any FileSystem, today: Date
    ) -> Outcome {
        let options: LintOptions
        do {
            options = try LintOptions.parse(arguments)
        } catch {
            return Outcome(output: "compat-lint: " + error.message + "\n" + usage, exitCode: exitUsage)
        }
        if options.showHelp { return Outcome(output: usage, exitCode: exitClean) }
        guard let rulesData = try? fileSystem.readData(at: options.rulesURL, maxBytes: maximumFileBytes) else {
            return Outcome(output: "compat-lint: cannot read " + options.rulesPath + "\n", exitCode: exitUsage)
        }
        let report = LintReport(annotate: environment["GITHUB_ACTIONS"] == "true")
        let document: RulesDocument
        do {
            document = try RulesDecoding.decodeStructure(rulesData)
        } catch {
            return report.render(findings: [DocumentChecks.finding(for: error)], notes: [], counts: (0, 0))
        }
        let (matrix, matrixFindings, matrixNotes) = loadMatrix(options, fileSystem: fileSystem)
        let (scenarios, scenarioNotes) = scenarioIndex(options, fileSystem: fileSystem)
        let linter = RulesLinter(
            rules: document, matrix: matrix, scenarioIDs: scenarios.ids,
            placeholderGateScenarioIDs: scenarios.placeholderGates, today: options.today ?? today,
            releaseMode: options.releaseMode)
        return report.render(
            findings: matrixFindings + linter.run(), notes: matrixNotes + scenarioNotes,
            counts: (document.rules.count, matrix?.entries.count ?? 0))
    }

    private static func loadMatrix(
        _ options: LintOptions, fileSystem: any FileSystem
    ) -> (MatrixDocument?, [LintFinding], [String]) {
        guard fileSystem.fileExists(at: options.matrixURL) else {
            return (nil, [], ["matrix " + options.matrixPath + " not found"])
        }
        do {
            let data = try fileSystem.readData(at: options.matrixURL, maxBytes: maximumFileBytes)
            return (try MatrixLoader.decode(data), [], [])
        } catch let error as RulesValidationError {
            let finding = LintFinding(severity: .error, code: .schemaInvalid, detail: "matrix " + error.detail)
            return (nil, [finding], [])
        } catch {
            let finding = LintFinding(severity: .error, code: .schemaInvalid, detail: "matrix file unreadable")
            return (nil, [finding], [])
        }
    }

    /// Scenario IDs are file names: `compat/scenarios/<id>.json` (PLT-R530). A file that cannot be read or parsed
    /// still counts as present (the scenario tests report it) but never as a placeholder gate (PLT-R422).
    private static func scenarioIndex(
        _ options: LintOptions, fileSystem: any FileSystem
    ) -> (ScenarioIndex, [String]) {
        guard let files = try? fileSystem.contentsOfDirectory(at: options.scenariosURL) else {
            return (ScenarioIndex(), ["scenario folder " + options.scenariosPath + " not found"])
        }
        var index = ScenarioIndex()
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            index.ids.insert(id)
            guard let data = try? fileSystem.readData(at: file, maxBytes: maximumScenarioBytes),
                let document = try? JSONDecoder().decode(JSONValue.self, from: data),
                PlaceholderGate.isDeclared(in: document)
            else { continue }
            index.placeholderGates.insert(id)
        }
        return (index, [])
    }

    /// Same cap as TestSupport's scenario loader.
    static let maximumScenarioBytes = 256 * 1024
}

struct ScenarioIndex {
    var ids: Set<String> = []
    var placeholderGates: Set<String> = []
}

struct LintUsageError: Error {
    let message: String
}

struct LintOptions {
    var rulesPath = "compat/rules.json"
    var matrixPath = "compat/matrix.json"
    var scenariosPath = "compat/scenarios"
    var releaseMode = false
    var today: Date?
    var showHelp = false

    var rulesURL: URL { URL(fileURLWithPath: rulesPath) }
    var matrixURL: URL { URL(fileURLWithPath: matrixPath) }
    var scenariosURL: URL { URL(fileURLWithPath: scenariosPath, isDirectory: true) }

    static func parse(_ arguments: [String]) throws(LintUsageError) -> LintOptions {
        var options = LintOptions()
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--release": options.releaseMode = true
            case "-h", "--help": options.showHelp = true
            case "--rules", "--matrix", "--scenarios", "--today":
                guard let value = remaining.popFirst() else {
                    throw LintUsageError(message: argument + " needs a value")
                }
                options = try options.setting(argument, to: value)
            default:
                throw LintUsageError(message: "unknown argument " + argument)
            }
        }
        return options
    }

    private func setting(_ option: String, to value: String) throws(LintUsageError) -> LintOptions {
        var copy = self
        switch option {
        case "--rules": copy.rulesPath = value
        case "--matrix": copy.matrixPath = value
        case "--scenarios": copy.scenariosPath = value
        default:
            guard let day = ISODay(value) else { throw LintUsageError(message: "--today needs YYYY-MM-DD") }
            copy.today = Date(timeIntervalSince1970: Double(day.ordinal) * 86_400)
        }
        return copy
    }
}

/// Renders findings, errors first, one per line; GitHub annotations when running in Actions.
struct LintReport {
    let annotate: Bool

    func render(
        findings: [LintFinding], notes: [String], counts: (rules: Int, rows: Int)
    ) -> CompatLintCommand.Outcome {
        let ordered = findings.filter { $0.severity == .error } + findings.filter { $0.severity == .warning }
        var lines = notes.map { "note: " + $0 }
        lines += ordered.map(line(for:))
        let errors = findings.filter { $0.severity == .error }.count
        let warnings = findings.count - errors
        lines.append(
            "compat-lint: " + String(counts.rules) + " rule(s), " + String(counts.rows) + " matrix row(s), "
                + String(errors) + " error(s), " + String(warnings) + " warning(s)")
        let exitCode = errors > 0 ? CompatLintCommand.exitFindings : CompatLintCommand.exitClean
        return CompatLintCommand.Outcome(output: lines.joined(separator: "\n") + "\n", exitCode: exitCode)
    }

    private func line(for finding: LintFinding) -> String {
        let prefix = annotate ? "::" + finding.severity.rawValue + "::" : finding.severity.rawValue + ": "
        var subject = finding.code.rawValue
        if let rule = finding.rule { subject += " [rule " + rule.rawValue + "]" }
        if let bundle = finding.bundle { subject += " [app " + bundle.rawValue + "]" }
        return prefix + subject + ": " + (finding.detail ?? finding.code.explanation)
    }
}

extension LintCode {
    /// Default text when a finding carries no detail.
    var explanation: String {
        switch self {
        case .schemaInvalid: "does not match the JSON Schema"
        case .missingProvenance: "missing provenance (PLT-R505)"
        case .missingTest: "missing test reference (PLT-R505)"
        case .noPassingTestedEntry: "no passing tested entry (5.4)"
        case .unverifiedTestedEntry: "tested entry without an ISO date (VERIFY)"
        case .unknownScenario: "scenario file not found (PLT-R530)"
        case .reviewByPassed: "reviewBy has passed (PLT-R506)"
        case .reviewByPassedOver30Days: "reviewBy passed more than 30 days ago (PLT-R506)"
        case .reviewByMoreThan12Months: "reviewBy more than 12 months ahead (PLT-R506)"
        case .identicalMatchSignature: "identical match signature (PLT-R521)"
        case .placeholderWithoutGateTest: "placeholder without its gate (PLT-R422)"
        case .manualTestWithoutMatrixRow: "manual scenario without a matrix row (PLT-R531)"
        case .manualMatrixRowUnverified: "matrix row not verified yet (PLT-R531)"
        case .tier1MatrixRowOlderThan90Days: "Tier 1 row older than 90 days (PLT-R531)"
        case .matrixRuleUnknown: "matrix ruleId is not a shipped rule"
        case .pasteWithoutOptIn: "paste without requiresUserOptIn (PLT-R460)"
        case .lookaheadRevisionWithoutEditStrategy: "lookaheadRevision on a strategy that cannot carry it (PLT-R357)"
        case .lookaheadRevisionWithoutRestoreHotkey: "lookaheadRevision where the restore key is off (PLT-R357)"
        }
    }
}
