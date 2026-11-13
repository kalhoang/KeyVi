// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `compat-harness` commands (PLT-R530, PLT-R821, QA-R16, QA-R21). The executable (Sources/CompatHarness)
// only parses arguments and supplies the live services; everything else is here so it is tested. Dry runs
// and `coverage` never touch `environment.live`. Live runs: HarnessLiveCommands.swift, HarnessSession.swift,
// HarnessMeasurements.swift.

internal import AppModel
internal import Foundation

public struct Harness: Sendable {
    let options: HarnessOptions
    let environment: HarnessEnvironment

    public init(options: HarnessOptions, environment: HarnessEnvironment) {
        self.options = options
        self.environment = environment
    }

    public func execute() async -> HarnessExit {
        switch options.command {
        case .help:
            environment.console.emit(HarnessCommandLine.usage)
            return .success
        case .coverage: return coverage()
        case .run: return options.dryRun ? planScenarios() : await runScenarios()
        case .soak: return options.dryRun ? planSoak() : await runSoak()
        case .bench: return options.dryRun ? planBench() : await runBench()
        case .egress: return options.dryRun ? planEgress() : await runEgress()
        }
    }

    // MARK: Inputs

    var repository: URL { URL(fileURLWithPath: options.repository, isDirectory: true).standardizedFileURL }

    func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.appendingPathComponent(path)
    }

    var targets: HarnessTargets {
        let brandFile = repository.appendingPathComponent("scripts/brand.env")
        let brand = (try? environment.fileSystem.readData(at: brandFile, maxBytes: 64 * 1024))
            .map { String(decoding: $0, as: UTF8.self) }
        return HarnessTargets.resolve(
            repository: repository, brandEnvironment: brand, testHost: options.testHostBundleID,
            appUnderTest: options.appBundleID)
    }

    /// Loaded scenarios filtered by `--only`; nil (after printing why) when loading fails.
    func selectedScenarios() -> [Scenario]? {
        let loaded: [Scenario]
        do {
            loaded = try ScenarioLoader(fileSystem: environment.fileSystem).load(directory: url(options.scenarios))
        } catch {
            environment.console.emitError("compat-harness: " + String(describing: error))
            return nil
        }
        guard !options.only.isEmpty else { return loaded }
        let unknown = options.only.filter { pattern in !loaded.contains { Self.matches($0.id, pattern) } }
        guard unknown.isEmpty else {
            environment.console.emitError(
                "compat-harness: unknown scenario id(s) " + unknown.sorted().joined(separator: ", "))
            return nil
        }
        return loaded.filter { scenario in options.only.contains { Self.matches(scenario.id, $0) } }
    }

    /// `--only` entries are scenario ids; one ending in `*` selects every id with that prefix (`testhost.*`, the
    /// QA-R11 TestHost suite).
    static func matches(_ id: String, _ pattern: String) -> Bool {
        pattern.hasSuffix("*") ? id.hasPrefix(String(pattern.dropLast())) : id == pattern
    }

    func unresolved(_ scenarios: [Scenario], _ targets: HarnessTargets) -> [String] {
        scenarios.filter { targets.resolve($0.targetBundleId) == nil }.map(\.id)
    }

    // MARK: coverage

    func coverage() -> HarnessExit {
        let rulesFile = url(options.rules)
        guard environment.fileSystem.fileExists(at: rulesFile) else {
            environment.console.emit("compat-harness coverage: " + options.rules + " not found, nothing to check")
            return .success
        }
        do {
            let ids = try ScenarioLoader(fileSystem: environment.fileSystem).scenarioFiles(in: url(options.scenarios))
                .map { $0.deletingPathExtension().lastPathComponent }
            let data = try environment.fileSystem.readData(at: rulesFile, maxBytes: 8 << 20)
            let rules = try RuleScenarioCoverage.ruleScenarios(rulesData: data).count
            let gaps = try RuleScenarioCoverage.gaps(rulesData: data, scenarioIDs: Set(ids))
            HarnessPlans.coverage(gaps, rules: rules, file: options.rules).forEach(environment.console.emit)
            return gaps.isEmpty ? .success : .failure
        } catch {
            environment.console.emitError("compat-harness coverage: " + String(describing: error))
            return .failure
        }
    }

    // MARK: Dry runs

    func planScenarios() -> HarnessExit {
        guard let scenarios = selectedScenarios(), let profiles = loadProfiles() else { return .failure }
        let targets = targets
        HarnessPlans.scenarioPlan(scenarios, targets: targets, options: options, profiles: profiles)
            .forEach(environment.console.emit)
        var exit = HarnessExit.success
        if environment.fileSystem.fileExists(at: url(options.rules)) {
            exit = coverage() == .success ? exit : .failure
        }
        let problems = planProblems(scenarios, profiles: profiles)
        for problem in problems { environment.console.emitError("compat-harness: " + problem) }
        if !problems.isEmpty { exit = .failure }
        let missing = unresolved(scenarios, targets)
        if !missing.isEmpty {
            environment.console.emitError("compat-harness: unresolved target in " + missing.joined(separator: ", "))
            exit = .failure
        }
        return exit
    }

    /// Profiles that name unknown scenarios or rules, and scenario files that use a setup action the scenario
    /// schema does not list yet (`ScenarioValidator.pendingSchemaActions`).
    func planProblems(_ scenarios: [Scenario], profiles: [AppProfile]) -> [String] {
        let loader = ScenarioLoader(fileSystem: environment.fileSystem)
        let ids = Set(
            ((try? loader.scenarioFiles(in: url(options.scenarios))) ?? []).map {
                $0.deletingPathExtension().lastPathComponent
            })
        let rules = rulesData().flatMap { try? RuleScenarioCoverage.ruleScenarios(rulesData: $0) } ?? []
        var problems = AppProfileLoader.problems(profiles, scenarioIDs: ids, shippedRuleIDs: Set(rules.map(\.rule)))
        for scenario in scenarios {
            let pending = scenario.setup.map(\.action).filter(ScenarioValidator.pendingSchemaActions.contains)
            if let action = pending.first {
                problems.append(
                    scenario.id + " uses " + action.rawValue
                        + ", which compat/schema/scenario.schema.json does not list yet")
            }
        }
        return problems
    }

    func soakTargets() -> [Scenario]? {
        guard let all = selectedScenarios() else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let targets = options.targets.compactMap { byID[$0] }
        guard targets.count == options.targets.count, !targets.isEmpty, targets.allSatisfy({ $0.method == .telex })
        else {
            environment.console.emitError(
                "compat-harness soak: --targets must name existing Telex scenarios: "
                    + options.targets.joined(separator: ", "))
            return nil
        }
        return targets
    }

    var soakProfile: Scenario.TimingProfile { options.profile ?? .fast }

    func planSoak() -> HarnessExit {
        guard let targets = soakTargets() else { return .failure }
        let plan = SoakPlan.make(
            keystrokes: options.keystrokes, targets: targets, seed: options.seed,
            chunkKeystrokes: options.chunkKeystrokes)
        HarnessPlans.soakPlan(plan, targets: targets, resolved: self.targets, profile: soakProfile)
            .forEach(environment.console.emit)
        return unresolved(targets, self.targets).isEmpty ? .success : .failure
    }

    func planBench() -> HarnessExit {
        let metrics = options.metrics.compactMap(PlatformGates.metric(named:))
        HarnessPlans.benchPlan(metrics, options: options, targets: targets, baseline: loadBaseline())
            .forEach(environment.console.emit)
        return .success
    }

    // MARK: Output

    func write(_ data: Data, to path: String) throws {
        let file = url(path)
        try environment.fileSystem.createDirectory(
            at: file.deletingLastPathComponent(), permissions: .ownerOnlyDirectory)
        try environment.fileSystem.writeAtomically(data, to: file, permissions: .ownerOnlyFile)
    }

    static func json<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
