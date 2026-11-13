// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The launch path with fakes (W2-A acceptance): order of the steps, safe mode after three crashes
// (PLT-R1009), the move offer before any permission request (PLT-R710), the legacy folder moved before the
// settings load (ADR 0307), and S1 ready-after-launch under 300 ms. Workstream W2-A.

import AppModel
import CompatRules
import Foundation
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing

@testable import InputHost

/// Records the steps in call order; each step can be customised.
@MainActor
final class RecordingSteps: LaunchSteps {
    enum Step: Equatable {
        case location, migrate, load, rules, host
        case shell(safeMode: Bool)
        case onboarding, updater
    }

    var calls: [Step] = []
    var location: () async -> LaunchLocationDecision = { .proceed }
    var migrate: () -> Void = {}
    var load: () async -> SettingsState = { SettingsState() }
    var host: (RulesLoadResult, SettingsState) -> Void = { _, _ in }

    func resolveLocation() async -> LaunchLocationDecision {
        calls.append(.location)
        return await location()
    }

    func migrateLegacyStorage() {
        calls.append(.migrate)
        migrate()
    }

    func loadSettings() async -> SettingsState {
        calls.append(.load)
        return await load()
    }

    func loadRules() -> RulesLoadResult {
        calls.append(.rules)
        return HostRig.shippedRules
    }

    func startHost(rules: RulesLoadResult, settings: SettingsState) {
        calls.append(.host)
        host(rules, settings)
    }

    func showShell(settings: SettingsState, safeMode: Bool) { calls.append(.shell(safeMode: safeMode)) }
    func presentOnboarding(settings: SettingsState) { calls.append(.onboarding) }
    func startUpdater(settings: SettingsState) { calls.append(.updater) }
}

/// `rename(2)` semantics over the in-memory file system: a moved folder takes its contents with it (the
/// TestSupport fake moves only the folder's own node).
struct RenamingFileSystem: FileSystem {
    let base: InMemoryFileSystem

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func readData(at url: URL, maxBytes: Int) throws -> Data { try base.readData(at: url, maxBytes: maxBytes) }
    func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        try base.writeAtomically(data, to: url, permissions: permissions)
    }
    func append(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        try base.append(data, to: url, permissions: permissions)
    }
    func createDirectory(at url: URL, permissions: FilePermissions) throws {
        try base.createDirectory(at: url, permissions: permissions)
    }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func attributes(at url: URL) throws -> FileAttributes { try base.attributes(at: url) }
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        try base.setExcludedFromBackup(excluded, at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        let prefix = source.path + "/"
        let children = base.nodes.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        try base.moveItem(at: source, to: destination)
        for (path, node) in children {
            let target = URL(fileURLWithPath: destination.path + "/" + path.dropFirst(prefix.count))
            if let data = node.data {
                try base.writeAtomically(data, to: target, permissions: node.permissions)
            } else {
                try base.createDirectory(at: target, permissions: node.permissions)
            }
            try base.removeItem(at: URL(fileURLWithPath: path))
        }
    }
}

@MainActor
private func sequence(
    _ steps: RecordingSteps, guard launchGuard: LaunchGuard = LaunchGuard(store: InMemoryKeyValueStore()),
    version: String = "0.1.0 (1)", scheduler: ManualScheduler = ManualScheduler(clock: ManualClock())
) -> LaunchSequence {
    LaunchSequence(
        launchGuard: launchGuard, appVersion: version, wallClock: FixedWallClock(), scheduler: scheduler,
        steps: steps)
}

@Suite("Launch sequence (contracts.md 12, PLT-R710, PLT-R1009)")
@MainActor
struct LaunchSequenceTests {
    @Test func firstLaunchRunsEveryStepInOrderWithOnboarding() async {
        let steps = RecordingSteps()
        let launch = sequence(steps)
        #expect(await launch.run() == .running(safeMode: false))
        #expect(
            steps.calls == [.location, .migrate, .load, .rules, .host, .shell(safeMode: false), .onboarding, .updater])
        #expect(launch.stage == .updaterStarted)
        #expect(await launch.run() == .running(safeMode: false), "runs once")
        #expect(steps.calls.count == 8)
    }

    @Test func completedOnboardingIsNotShownAgain_PRD_R40() async {
        let steps = RecordingSteps()
        var user = UserSettings()
        user.onboarding.completedVersion = "0.1.0"
        let settings = SettingsState(user: user)
        steps.load = { settings }
        _ = await sequence(steps).run()
        #expect(!steps.calls.contains(.onboarding))
    }

    @Test func safeModeAfterThreeCrashesAndAnUpdateClearsIt_PLT_R1009() async {
        let store = InMemoryKeyValueStore()
        let launchGuard = LaunchGuard(store: store)
        for _ in 0..<3 {
            let outcome = await sequence(RecordingSteps(), guard: launchGuard).run()
            #expect(outcome == .running(safeMode: false))
        }
        let steps = RecordingSteps()
        #expect(await sequence(steps, guard: launchGuard).run() == .running(safeMode: true), "fourth launch")
        #expect(steps.calls.contains(.shell(safeMode: true)))
        #expect(!steps.calls.contains(.onboarding), "safe mode never runs onboarding over real settings")
        let updated = await sequence(RecordingSteps(), guard: launchGuard, version: "0.1.1 (2)").run()
        #expect(updated == .running(safeMode: false), "W1-B: a new bundle version clears the crash loop")
    }

    @Test func safeModeReachesTheSettingsStore_PLT_R1009() async {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, #"{"schemaVersion":1,"writtenBy":"0.1.0","settings":{"typingMethod":"vni"}}"#)
        for _ in 0..<3 { _ = harness.launchGuard.beginLaunch(now: 1_800_000_000) }
        let steps = RecordingSteps()
        var loaded: SettingsState?
        steps.load = {
            let state = await harness.store.load()
            loaded = state
            return state
        }
        #expect(await sequence(steps, guard: harness.launchGuard).run() == .running(safeMode: true))
        #expect(loaded?.safeMode == true)
        #expect(loaded?.effective.typingMethod == .telex, "defaults in memory, files untouched")
    }

    @Test func survivingSixtySecondsEndsTheCrashCount() async {
        let launchGuard = LaunchGuard(store: InMemoryKeyValueStore())
        let scheduler = ManualScheduler(clock: ManualClock())
        _ = await sequence(RecordingSteps(), guard: launchGuard, scheduler: scheduler).run()
        _ = await sequence(RecordingSteps(), guard: launchGuard, scheduler: scheduler).run()
        #expect(launchGuard.recentCrashes == 1)
        scheduler.advance(by: .seconds(60))
        #expect(launchGuard.recentCrashes == 0)
        let launch = sequence(RecordingSteps(), guard: launchGuard, scheduler: scheduler)
        _ = await launch.run()
        launch.terminate()
        #expect(launchGuard.recentCrashes == 0, "a clean quit is not a crash")
    }

    @Test(arguments: [LaunchLocationDecision.relocating, .quit])
    func leavingAtTheLocationStepDoesNothingElse_PLT_R710(decision: LaunchLocationDecision) async {
        let launchGuard = LaunchGuard(store: InMemoryKeyValueStore())
        let steps = RecordingSteps()
        steps.location = { decision }
        let outcome = await sequence(steps, guard: launchGuard).run()
        #expect(outcome == (decision == .quit ? .quit : .relocating))
        #expect(steps.calls == [.location], "no settings, no host, no permission request")
        _ = await sequence(RecordingSteps(), guard: launchGuard).run()
        #expect(launchGuard.recentCrashes == 0, "a deliberate quit is not a crash")
    }

    @Test func translocatedLaunchOffersTheMoveBeforeAnyPermissionRequest_PLT_R710() async {
        let permissions = FakePermissionProbe(trusted: false, post: false, listen: false)
        let files = FakeRelocationFiles(existing: [])
        let relauncher = FakeRelauncher()
        var offered = 0
        let gate = LocationGate<String>(
            verdict: { .mustMove("translocated") },
            offer: { _ in
                offered += 1
                return true
            },
            reportFailure: { _ in }, relocator: FakeRelocationFiles.relocator(files, relauncher),
            bundleURL: FakeRelocationFiles.translocated)
        let steps = RecordingSteps()
        steps.location = { await gate.resolve() }
        steps.host = { _, _ in permissions.promptForAccessibility() }
        #expect(await sequence(steps).run() == .relocating)
        #expect(offered == 1)
        #expect(permissions.accessibilityPromptCount == 0)
        #expect(relauncher.launched == [FakeRelocationFiles.destination])
    }

    @Test func legacyFolderMovesBeforeTheSettingsLoad_ADR0307() async {
        let harness = SettingsStoreHarness()
        let legacy = URL(fileURLWithPath: "/Legacy Name", isDirectory: true)
        try? harness.memory.createDirectory(at: legacy, permissions: .ownerOnlyDirectory)
        try? harness.memory.writeAtomically(
            Data(#"{"schemaVersion":1,"writtenBy":"0.1.0","settings":{"typingMethod":"vni"}}"#.utf8),
            to: legacy.appendingPathComponent("settings.json"), permissions: .ownerOnlyFile)
        let steps = RecordingSteps()
        steps.migrate = {
            _ = LegacyStorageMigrator.migrate(
                current: "Settings", legacyNames: ["Legacy Name"],
                bases: [URL(fileURLWithPath: "/", isDirectory: true)],
                fileSystem: RenamingFileSystem(base: harness.memory))
        }
        var loaded: SettingsState?
        steps.load = {
            let state = await harness.store.load()
            loaded = state
            return state
        }
        _ = await sequence(steps, guard: harness.launchGuard).run()
        #expect(loaded?.effective.typingMethod == .vni, "the moved file was read")
        #expect(!harness.memory.fileExists(at: legacy))
    }

    /// S1 with fakes: from the first launch step to `ready`, including the bundled word lists and the engine
    /// catalog. The best of up to ten launches is compared, stopping at the first one inside the target: the
    /// parallel test run itself loads the machine for its first seconds, so a fixed count of three let a busy
    /// moment decide the result.
    @Test func readyAfterLaunchUnder300Milliseconds_S1() async {
        let target: TimeSpan = .milliseconds(300)
        var best: TimeSpan = .seconds(60)
        let attempts = AllocationCounter.isSanitizerActive ? 1 : 10
        for _ in 0..<attempts where best >= target {
            let rig = HostRig(realResources: true)
            let steps = RecordingSteps()
            steps.load = { await rig.store.store.load() }
            steps.host = { rules, settings in rig.controller.start(rules: rules, settings: settings) }
            let clock = MachClock()
            let started = clock.now()
            _ = await sequence(steps).run()
            rig.settle()
            let elapsed = clock.now().duration(since: started)
            #expect(rig.controller.state == .ready(.vietnamese))
            best = min(best, elapsed)
            rig.stop()
        }
        // A sanitizer slows every instruction several times over; the timing is meaningful only without one.
        guard !AllocationCounter.isSanitizerActive else { return }
        #expect(best < target, "S1 target, best of up to ten launches: \(best)")
    }
}
