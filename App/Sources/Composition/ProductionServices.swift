// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production wiring of the composition root: storage paths (ADR 0307, PLT-R903), the diagnostics services
// (PLT-R903, PLT-R905, PLT-R1206), the platform services of the input host (contracts.md section 3) and the
// file operations of the move to Applications (PLT-R710). Workstream W2-A.

import AppKit
import AppModel
import Diagnostics
import Foundation
import Injection
import InputHost
import RealtimeSupport
import SettingsStore
import ShellCore

/// Where the app keeps its files; `<folder>` is `Brand.storageFolderName` (ADR 0307).
struct StoragePaths {
    let applicationSupport: URL
    let logs: URL
    var captures: URL { logs.appendingPathComponent("captures", isDirectory: true) }
    /// The bases `LegacyStorageMigrator` looks in for a renamed product's folders.
    let bases: [URL]

    init(folder: String, fileManager: FileManager = .default) {
        let library =
            fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let supportBase = library.appendingPathComponent("Application Support", isDirectory: true)
        let logsBase = library.appendingPathComponent("Logs", isDirectory: true)
        applicationSupport = supportBase.appendingPathComponent(folder, isDirectory: true)
        logs = logsBase.appendingPathComponent(folder, isDirectory: true)
        bases = [supportBase, logsBase]
    }
}

/// Logger, health log, capture, metrics and the redaction salt, with their maintenance timers (W1-A request).
/// The cadence and the salt rules are `DiagnosticsMaintenance` and `RedactionSaltStore` (tested in AppCore).
@MainActor
final class DiagnosticsWiring {
    let logger: DiagnosticsLogger
    let health: HealthEventLog
    let capture: CaptureController
    let metrics = PlatformMetrics()
    let tapLog = TapLogRing()
    let redactionSalt: RedactionSalt
    #if DEV_RECORDER
    /// PLT-R904A: the dev builds' always-on typing recorder (ADR 0007).
    let devRecorder: DevRecorderController
    #endif
    private let utility: DispatchQueue
    private let scheduler: DispatchTimerScheduler
    private var timers: [any ScheduledTimer] = []

    init(paths: StoragePaths, subsystem: String, utility: DispatchQueue, defaults: UserDefaults) {
        self.utility = utility
        scheduler = DispatchTimerScheduler(queue: utility)
        let fileSystem = LocalFileSystem()
        logger = DiagnosticsLogger(
            policy: LogStorePolicy(directory: paths.logs), fileSystem: fileSystem, clock: SystemWallClock(),
            subsystem: subsystem)
        health = HealthEventLog(mirror: logger)
        #if DEV_RECORDER
        // The recorder's marker and readback requests run on their own queue, off the tap and the utility queue.
        let devAttention = DispatchQueue(label: subsystem + ".dev-recorder", qos: .utility)
        capture = CaptureController(
            directory: paths.captures, fileSystem: fileSystem, wallClock: SystemWallClock(), clock: MachClock(),
            scheduler: scheduler, devAttentionQueue: devAttention)
        devRecorder = DevRecorderController(recorder: capture.dev, attentionQueue: devAttention)
        #else
        capture = CaptureController(
            directory: paths.captures, fileSystem: fileSystem, wallClock: SystemWallClock(), clock: MachClock(),
            scheduler: scheduler)
        #endif
        redactionSalt = RedactionSaltStore.load(from: UserDefaultsSaltStorage(defaults: defaults))
    }

    /// Log rotation at launch and every 6 hours; capture purge at launch and hourly (utility queue). Started once
    /// the launch sequence reached `.running`, so this file I/O never delays the host start (S1).
    func startMaintenance() {
        guard timers.isEmpty else { return }
        let logger = self.logger
        let capture = self.capture
        let maintenance = DiagnosticsMaintenance(
            wallClock: SystemWallClock(), rotate: { logger.maintain() }, purge: { capture.purgeExpired(now: $0) })
        timers = maintenance.start(on: scheduler)
    }

    /// Quit: writes what is buffered (PRD-R46: events before a crash or quit stay explainable). Returned as an
    /// operation so the quit runs it off the main actor (AppEnvironment+Quit.swift).
    func flushOperation() -> @Sendable () -> Void {
        let logger = self.logger
        let utility = self.utility
        #if DEV_RECORDER
        let recorder = capture.dev
        return {
            utility.sync {
                logger.flush()
                recorder.stop()  // PLT-R904A: what is queued is written, then a stop line
            }
        }
        #else
        return { utility.sync { logger.flush() } }
        #endif
    }
}

extension InputHostDependencies {
    /// The real platform services (contracts.md section 3). Only the running app uses them; tests use fakes.
    @MainActor
    static func production(
        diagnostics: DiagnosticsWiring, keyValues: any KeyValueStore, utility: DispatchQueue
    ) -> InputHostDependencies {
        InputHostDependencies(
            tapFactory: CGEventTapFactory(), poster: CGEventPoster(), fieldAccess: AXFocusedFieldAccess(),
            pasteboard: NSPasteboardAccess(pasteboardName: nil), ax: SystemAXProvider(),
            processes: SystemProcessIdentityProvider(), bundleInspector: FileSystemBundleInspector(),
            inputSources: TISInputSourceProvider(), layoutBuilder: UCKeyTranslateLayoutBuilder(),
            secureInput: SystemSecureInputProbe(), permissions: SystemPermissionProbe(), workspace: NSWorkspaceEvents(),
            keyValueStore: keyValues, clock: MachClock(), scheduler: DispatchTimerScheduler(queue: utility),
            wallClock: SystemWallClock(), metrics: diagnostics.metrics, health: diagnostics.health,
            logger: diagnostics.logger, tapLog: diagnostics.tapLog, capture: diagnostics.capture,
            utilityQueue: utility)
    }
}

/// The app's user defaults as the redaction salt's storage.
struct UserDefaultsSaltStorage: SaltStorage, @unchecked Sendable {
    // UserDefaults is documented as thread-safe; it is not marked Sendable.
    let defaults: UserDefaults
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { defaults.set(data, forKey: key) }
}

/// FileManager-backed move (PLT-R710). Replaced and original copies go to the Trash, never deleted.
struct FileManagerRelocationFiles: RelocationFileOperations {
    func itemExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func moveToTrash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    func isRemovable(_ url: URL) -> Bool {
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true
        return !readOnly && !url.path.contains("/AppTranslocation/")
            && FileManager.default.isDeletableFile(atPath: url.path)
    }

    func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    }

    func clearQuarantine(at url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = nil
        var target = url
        try target.setResourceValues(values)
    }
}

/// Opens the moved copy as a new instance, then quits this one (PLT-R710). `beforeLaunch` marks the launch as
/// survived first, so the copy's crash-loop guard does not count this deliberate quit (PLT-R1009).
@MainActor
final class WorkspaceRelauncher: AppRelauncher {
    private let beforeLaunch: @MainActor () -> Void

    init(beforeLaunch: @escaping @MainActor () -> Void) { self.beforeLaunch = beforeLaunch }

    func launch(_ bundleURL: URL) async throws {
        beforeLaunch()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    func terminate() { NSApp.terminate(nil) }
}
