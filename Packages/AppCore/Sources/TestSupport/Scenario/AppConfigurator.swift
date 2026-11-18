// SPDX-License-Identifier: GPL-3.0-or-later
//
// Puts the app under test into the configuration a scenario needs (AppConfiguration.swift): quit it (its own
// quit path flushes its settings first, PLT-R1003), back up its four settings files once, write the new ones, start
// it again and wait until it is ready. `restore()` puts the backed-up files back after the run and starts the app
// again only when it was running before the first apply. Only the runner does this, to the test build's own settings
// folder; tests drive it over InMemoryFileSystem.

public import AppModel
public import Foundation
public import RealtimeSupport
public import SettingsStore

/// Starts and stops the app under test. Live: NSRunningApplication and NSWorkspace (CompatHarness/Live).
public protocol AppUnderTestControl: Sendable {
    func isRunning() -> Bool
    /// Process of the running app (egress sampling), nil when it is not running.
    func processIdentifier() -> Int32?
    /// Asks the app to quit and returns once it has exited.
    func quit() async throws
    func launch() async throws
}

public protocol AppConfigurator: Sendable {
    /// Does nothing when `configuration` is the one applied last.
    func apply(_ configuration: AppConfiguration) async throws
    /// Puts back the files found before the first `apply`, and restarts the app only when it was running before
    /// that `apply`: the restored files may turn the automatic update check and install (D19, D20) on, and the test
    /// build carries the production feed (PLT-R1101, integration-suite.md section 10.10), so the harness adds no
    /// launch of its own after the run. Nothing to do before `apply`.
    func restore() async throws
}

public final class SettingsFileAppConfigurator: AppConfigurator, Sendable {
    /// Ready wait without hooks: twice the S1 gate (8.1, process start to tap active at most 1 s).
    public static let settleNanoseconds: UInt64 = 2_000_000_000
    public static let readyTimeoutNanoseconds: UInt64 = 10_000_000_000
    static let pollNanoseconds: UInt64 = 100_000_000
    static let maximumDocumentBytes = 5 << 20

    private struct State {
        var backedUp: Set<SettingsFile>? = nil
        /// Whether the app was running before the first `apply` of the run; `restore()` starts it again only then.
        var wasRunning = false
        var current: AppConfiguration? = nil
        /// Set when the hooks timed out once: the app is not the INTEGRATION_HOOKS build, so asking again would
        /// only add the channel's timeout to every switch.
        var hooksSilent = false
    }

    private let location: StorageLocation
    private let backupDirectory: URL
    private let fileSystem: any FileSystem
    private let control: any AppUnderTestControl
    private let documents: AppSettingsDocuments
    private let hooks: (any AppHookClient)?
    private let clock: any MonotonicClock
    private let sleeper: any HarnessSleeper
    private let state = Mutex(State())

    public init(
        location: StorageLocation, backupDirectory: URL, fileSystem: any FileSystem, control: any AppUnderTestControl,
        documents: AppSettingsDocuments, hooks: (any AppHookClient)?, clock: any MonotonicClock,
        sleeper: any HarnessSleeper
    ) {
        self.location = location
        self.backupDirectory = backupDirectory
        self.fileSystem = fileSystem
        self.control = control
        self.documents = documents
        self.hooks = hooks
        self.clock = clock
        self.sleeper = sleeper
    }

    public func apply(_ configuration: AppConfiguration) async throws {
        guard state.withLock({ $0.current }) != configuration else { return }
        let running = control.isRunning()
        if state.withLock({ $0.backedUp }) == nil { state.withLock { $0.wasRunning = running } }
        if running { try await control.quit() }
        try backUpOnce()
        let files = try documents.documents(for: configuration, onboarding: try onboarding())
        try fileSystem.createDirectory(at: location.directory, permissions: .ownerOnlyDirectory)
        for (file, data) in files.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try fileSystem.writeAtomically(data, to: location.url(for: file), permissions: .ownerOnlyFile)
        }
        try await control.launch()
        try await awaitReady()
        // Only a configuration the app started with counts as applied: after a failed launch the next apply of the
        // same configuration tries again.
        state.withLock { $0.current = configuration }
    }

    public func restore() async throws {
        guard let (saved, wasRunning) = state.withLock({ state in state.backedUp.map { ($0, state.wasRunning) } })
        else { return }
        if control.isRunning() { try await control.quit() }
        for file in SettingsFile.allCases {
            let target = location.url(for: file)
            if saved.contains(file) {
                let data = try fileSystem.readData(at: backupURL(file), maxBytes: Self.maximumDocumentBytes)
                try fileSystem.writeAtomically(data, to: target, permissions: .ownerOnlyFile)
            } else if fileSystem.fileExists(at: target) {
                try fileSystem.removeItem(at: target)
            }
        }
        state.withLock { $0 = State(hooksSilent: $0.hooksSilent) }
        guard wasRunning else { return }
        try await control.launch()
        try await awaitReady()
    }

    func backupURL(_ file: SettingsFile) -> URL { backupDirectory.appendingPathComponent(file.rawValue) }

    /// Copies the files that exist, once per run; remembers which did not, so `restore` removes them.
    private func backUpOnce() throws {
        guard state.withLock({ $0.backedUp }) == nil else { return }
        try fileSystem.createDirectory(at: backupDirectory, permissions: .ownerOnlyDirectory)
        var saved: Set<SettingsFile> = []
        for file in SettingsFile.allCases where fileSystem.fileExists(at: location.url(for: file)) {
            let data = try fileSystem.readData(at: location.url(for: file), maxBytes: Self.maximumDocumentBytes)
            try fileSystem.writeAtomically(data, to: backupURL(file), permissions: .ownerOnlyFile)
            saved.insert(file)
        }
        state.withLock { $0.backedUp = saved }
    }

    /// `onboarding` of the original settings file (the backup), so onboarding never reappears.
    private func onboarding() throws -> JSONValue? {
        guard state.withLock({ $0.backedUp?.contains(.settings) }) == true else { return nil }
        let data = try fileSystem.readData(at: backupURL(.settings), maxBytes: Self.maximumDocumentBytes)
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?["onboarding"]
    }

    /// With hooks: until the app reports a state other than `starting`. Without hooks, or when the app does not
    /// answer at all (not the INTEGRATION_HOOKS build, remembered after the first timeout): a fixed settle time.
    private func awaitReady() async throws {
        guard let hooks, !state.withLock({ $0.hooksSilent }) else {
            try await sleeper.sleep(nanoseconds: Self.settleNanoseconds)
            return
        }
        let deadline = clock.now().nanoseconds &+ Self.readyTimeoutNanoseconds
        while true {
            do {
                if try await hooks.state().state != .starting { return }
            } catch AppHookError.timeout {
                state.withLock { $0.hooksSilent = true }
                try await sleeper.sleep(nanoseconds: Self.settleNanoseconds)
                return
            } catch {
                // A rejected or malformed answer while the app starts: ask again until the deadline.
            }
            guard clock.now().nanoseconds < deadline else { throw AppHookError.timeout(command: "state") }
            try await sleeper.sleep(nanoseconds: Self.pollNanoseconds)
        }
    }
}
