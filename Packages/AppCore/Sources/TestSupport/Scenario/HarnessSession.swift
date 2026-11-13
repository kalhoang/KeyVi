// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-run state of a live `compat-harness` command: the app profiles, the configurator that writes each scenario's
// configuration into the test build's settings (and restores them afterwards), and the integration hooks when the
// app under test answers them. Runner only; dry runs read the profiles but open no session.

internal import AppModel
internal import Foundation
internal import SettingsStore

struct HarnessSession {
    var profiles: [AppProfile]
    var configurator: (any AppConfigurator)?
    /// Nil when the app under test does not answer (not the INTEGRATION_HOOKS build).
    var hooks: (any AppHookClient)?
    var library: URL
}

extension Harness {
    /// Profiles of `--profiles`, nil (after printing why) when one is invalid.
    func loadProfiles() -> [AppProfile]? {
        do {
            return try AppProfileLoader.load(directory: url(options.profiles), fileSystem: environment.fileSystem)
        } catch {
            environment.console.emitError("compat-harness: " + String(describing: error))
            return nil
        }
    }

    /// compat/rules.json, when present.
    func rulesData() -> Data? {
        try? environment.fileSystem.readData(at: url(options.rules), maxBytes: 8 << 20)
    }

    /// `~/Library/Application Support/<folder>` of the app under test; nil without scripts/brand.env.
    func applicationSupport(library: URL, targets: HarnessTargets) -> URL? {
        targets.storageFolderName.map {
            library.appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Opens the session: starts the app under test on factory defaults (unless `--no-configure`), then asks it
    /// once whether it answers the integration hooks.
    func openSession(_ live: any LiveHarnessServices, targets: HarnessTargets) async throws -> HarnessSession {
        guard let profiles = loadProfiles() else { throw HarnessSessionError.invalidProfiles }
        let library = live.libraryDirectory()
        guard let support = applicationSupport(library: library, targets: targets) else {
            environment.console.emitError("compat-harness: scripts/brand.env missing, app configuration and hooks off")
            return HarnessSession(profiles: profiles, configurator: nil, hooks: nil, library: library)
        }
        let channel = FileDropHookChannel(
            directory: FileDropHookChannel.directory(applicationSupport: support), fileSystem: environment.fileSystem,
            clock: environment.clock, sleeper: environment.sleeper)
        channel.removeStaleFiles()
        var configurator: (any AppConfigurator)?
        if options.configureApp {
            let documents = AppSettingsDocuments(
                targets: targets, shippedActions: rulesData().map(AppSettingsDocuments.shippedActions) ?? [:])
            let configured = SettingsFileAppConfigurator(
                location: StorageLocation(directory: support),
                backupDirectory: url(outputDirectory + "/app-settings-backup"), fileSystem: environment.fileSystem,
                control: try live.appControl(targets: targets), documents: documents, hooks: channel,
                clock: environment.clock, sleeper: environment.sleeper)
            do {
                try await configured.apply(.factory)
            } catch {
                // The files may already be the harness's: put the originals back before giving up.
                await close(HarnessSession(profiles: profiles, configurator: configured, hooks: nil, library: library))
                throw error
            }
            configurator = configured
        }
        let answers = (try? await channel.state()) != nil
        environment.console.emit(
            "Integration hooks: "
                + (answers ? "answering" : "not answering (testHook steps need a person, T2 to T6 are skipped)"))
        return HarnessSession(
            profiles: profiles, configurator: configurator, hooks: answers ? channel : nil, library: library)
    }

    /// `--output` directory of `run` and `soak` (default .build/integration).
    var outputDirectory: String {
        switch options.command {
        case .run, .soak: options.output ?? ".build/integration"
        default:
            options.output.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ".build/integration"
        }
    }

    /// Opens the session, runs `body`, then restores the app's settings whether `body` returned or threw (ADR 0502:
    /// the runner keeps its own settings; a run that left the harness's files behind would back them up as the
    /// originals next time). `defer` cannot await, hence the explicit catch.
    func withSession<Value>(
        _ live: any LiveHarnessServices, targets: HarnessTargets, _ body: (HarnessSession) async throws -> Value
    ) async throws -> Value {
        let session = try await openSession(live, targets: targets)
        let value: Value
        do {
            value = try await body(session)
        } catch {
            await close(session)
            throw error
        }
        await close(session)
        return value
    }

    /// Puts the app's settings back; a failure is reported, never fatal.
    func close(_ session: HarnessSession) async {
        do {
            try await session.configurator?.restore()
        } catch {
            environment.console.emitError(
                "compat-harness: restoring the app's settings failed: " + String(describing: error))
        }
    }
}

enum HarnessSessionError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidProfiles
    var description: String { "invalid app profiles" }
}
