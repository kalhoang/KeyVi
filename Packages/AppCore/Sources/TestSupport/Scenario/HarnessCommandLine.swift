// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Command line of `compat-harness` (PLT-R530, PLT-R821, QA-R16; command lines agreed with the CI track in
// ADR 0502 and scripts/run-integration.sh). `--dry-run` on every subcommand loads and plans without posting
// a single event: the only mode allowed on the product owner's Mac and the mode hosted CI runs.

public import AppModel
public import Foundation

public struct HarnessOptions: Sendable, Hashable {
    public enum Command: String, Sendable, Hashable { case run, soak, bench, coverage, help }

    public var command: Command
    public var dryRun = false
    public var repository = "."
    public var scenarios = "compat/scenarios"
    public var rules = "compat/rules.json"
    public var output: String?
    public var report: String?
    public var profile: Scenario.TimingProfile?
    public var only: [String] = []
    public var seed: UInt64 = 0x5EED_CAFE
    public var keystrokes = 1_000_000
    public var targets = ["textedit.telex.basic", "chrome.page.textarea", "terminal.zsh"]
    public var chunkKeystrokes = SoakPlan.defaultChunkKeystrokes
    public var runs = 5
    public var metrics: [String] = PlatformGates.metrics.map(\.name)
    public var idleSeconds = 300
    public var typingSeconds = 300
    public var testHostBundleID: String?
    public var appBundleID: String?
    public var terminalCapture: String?
    public var webDrivers: [BundleKey: URL] = [:]

    public init(command: Command) { self.command = command }
}

public struct HarnessUsageError: Error, Sendable, Hashable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum HarnessCommandLine {
    public static let usage = """
        Usage: compat-harness <command> [options]

        Commands:
          run       run compatibility scenarios (self-hosted runner)
          soak      replay N keystrokes through the pipeline, check text, memory growth, stuck modifiers
          bench     measure the self-hosted 8.1 gates, median of --runs, ADR 0502 format version 1
          coverage  list rules in the rules file whose test.scenario has no scenario file
          help      show this help

        Common options:
          --dry-run                 load and plan only; posts no events (the only mode for developer Macs)
          --repository DIR          checkout root for scripts/brand.env and the local pages (default .)
          --scenarios DIR           scenario directory (default compat/scenarios)
          --testhost-bundle-id ID   TestHost bundle id (default APP_BUNDLE_ID_DEV.testhost from brand.env)
          --app-bundle-id ID        build under test (default APP_BUNDLE_ID_DEV from brand.env)
          --seed N                  timing and corpus seed

        run:      --output DIR | --report FILE, --profile normal|fast|burst, --only ID[,ID...],
                  --rules FILE, --webdriver BUNDLE=URL (repeatable), --terminal-capture FILE
        soak:     --keystrokes N (default 1000000), --targets ID[,ID...], --chunk N, --profile P, --output DIR
        bench:    --runs N (default 5), --output FILE, --metrics NAME[,NAME...], --idle-seconds N,
                  --typing-seconds N
        coverage: --rules FILE (default compat/rules.json)
        """

    public static func parse(_ arguments: [String]) throws(HarnessUsageError) -> HarnessOptions {
        guard let first = arguments.first else { return HarnessOptions(command: .help) }
        if first == "--help" || first == "-h" { return HarnessOptions(command: .help) }
        guard let command = HarnessOptions.Command(rawValue: first) else {
            throw HarnessUsageError("unknown command '" + first + "'")
        }
        var options = HarnessOptions(command: command)
        var rest = arguments.dropFirst()[...]
        while let flag = rest.popFirst() {
            if flag == "--dry-run" {
                options.dryRun = true
            } else if flag == "--help" || flag == "-h" {
                options.command = .help
            } else {
                guard let value = rest.popFirst() else { throw HarnessUsageError(flag + " needs a value") }
                try apply(flag, value, to: &options)
            }
        }
        return options
    }

    private static func apply(_ flag: String, _ value: String, to options: inout HarnessOptions) throws(HarnessUsageError) {
        switch flag {
        case "--repository": options.repository = value
        case "--scenarios": options.scenarios = value
        case "--rules": options.rules = value
        case "--output": options.output = value
        case "--report": options.report = value
        case "--profile":
            guard let profile = Scenario.TimingProfile(rawValue: value) else {
                throw HarnessUsageError("--profile must be normal, fast or burst")
            }
            options.profile = profile
        case "--only": options.only = list(value)
        case "--targets": options.targets = list(value)
        case "--metrics":
            let names = list(value)
            if let unknown = names.first(where: { PlatformGates.metric(named: $0) == nil }) {
                throw HarnessUsageError("unknown metric '" + unknown + "'")
            }
            options.metrics = names
        case "--seed": options.seed = try number(flag, value, minimum: 0)
        case "--keystrokes": options.keystrokes = try number(flag, value, minimum: SoakPlan.minimumKeystrokes)
        case "--chunk": options.chunkKeystrokes = try number(flag, value, minimum: SoakPlan.minimumKeystrokes)
        case "--runs": options.runs = try number(flag, value, minimum: 1)
        case "--idle-seconds": options.idleSeconds = try number(flag, value, minimum: 1)
        case "--typing-seconds": options.typingSeconds = try number(flag, value, minimum: 1)
        case "--testhost-bundle-id": options.testHostBundleID = try bundle(flag, value).rawValue
        case "--app-bundle-id": options.appBundleID = try bundle(flag, value).rawValue
        case "--terminal-capture": options.terminalCapture = value
        case "--webdriver": try addWebDriver(value, to: &options)
        default: throw HarnessUsageError("unknown option '" + flag + "'")
        }
    }

    private static func addWebDriver(_ value: String, to options: inout HarnessOptions) throws(HarnessUsageError) {
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let bundle = BundleKey(rawValue: parts[0]), let url = URL(string: parts[1]),
            url.scheme != nil
        else { throw HarnessUsageError("--webdriver needs BUNDLE=URL") }
        options.webDrivers[bundle] = url
    }

    private static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func number<Value: FixedWidthInteger>(
        _ flag: String, _ value: String, minimum: Value
    ) throws(HarnessUsageError) -> Value {
        guard let number = Value(value), number >= minimum else {
            throw HarnessUsageError(flag + " must be an integer of at least \(minimum)")
        }
        return number
    }

    private static func bundle(_ flag: String, _ value: String) throws(HarnessUsageError) -> BundleKey {
        guard let key = BundleKey(rawValue: value), !key.isExecutableHash else {
            throw HarnessUsageError(flag + " must be a bundle id")
        }
        return key
    }
}
