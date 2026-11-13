// SPDX-License-Identifier: LicenseRef-App-Pending
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
@MainActor
final class DiagnosticsWiring {
    static let saltDefaultsKey = "diagnostics.redactionSalt"
    /// PLT-R903 rotation and retention.
    static let maintenanceInterval: Duration = .seconds(6 * 3_600)
    /// PLT-R905: captures older than 24 hours are deleted.
    static let purgeInterval: Duration = .seconds(3_600)

    let logger: DiagnosticsLogger
    let health: HealthEventLog
    let capture: CaptureController
    let metrics = PlatformMetrics()
    let tapLog = TapLogRing()
    let redactionSalt: RedactionSalt
    private let utility: DispatchSerialQueue
    private let scheduler: DispatchTimerScheduler
    private var timers: [any ScheduledTimer] = []

    init(paths: StoragePaths, subsystem: String, utility: DispatchSerialQueue, defaults: UserDefaults) {
        self.utility = utility
        scheduler = DispatchTimerScheduler(queue: utility)
        let fileSystem = LocalFileSystem()
        logger = DiagnosticsLogger(
            policy: LogStorePolicy(directory: paths.logs), fileSystem: fileSystem, clock: SystemWallClock(),
            subsystem: subsystem)
        health = HealthEventLog(mirror: logger)
        capture = CaptureController(
            directory: paths.captures, fileSystem: fileSystem, wallClock: SystemWallClock(), clock: MachClock(),
            scheduler: scheduler)
        redactionSalt = Self.persistedSalt(defaults)
    }

    /// The salt that makes redacted values stable across reports of one installation (PLT-R1203).
    static func persistedSalt(_ defaults: UserDefaults) -> RedactionSalt {
        if let bytes = defaults.data(forKey: saltDefaultsKey), !bytes.isEmpty {
            return RedactionSalt(bytes: Array(bytes))
        }
        let salt = RedactionSalt.random()
        defaults.set(Data(salt.bytes), forKey: saltDefaultsKey)
        return salt
    }

    /// Log rotation at launch and every 6 hours; capture purge at launch and hourly (utility queue).
    func startMaintenance() {
        let logger = self.logger
        let capture = self.capture
        utility.async {
            logger.maintain()
            capture.purgeExpired(now: Date())
        }
        timers = [
            scheduler.scheduleRepeating(every: Self.maintenanceInterval, leeway: Self.maintenanceInterval / 10) {
                logger.maintain()
            },
            scheduler.scheduleRepeating(every: Self.purgeInterval, leeway: Self.purgeInterval / 10) {
                capture.purgeExpired(now: Date())
            },
        ]
    }

    /// Quit: write what is buffered (PRD-R46: events before a crash or quit stay explainable).
    func flush() {
        let logger = self.logger
        utility.sync { logger.flush() }
    }
}

extension InputHostDependencies {
    /// The real platform services (contracts.md section 3). Only the running app uses them; tests use fakes.
    @MainActor
    static func production(
        diagnostics: DiagnosticsWiring, keyValues: any KeyValueStore, utility: DispatchSerialQueue
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

/// Settings and macros windows are owned by W2-B; until its hotkey recorder API is merged, onboarding's
/// "Đổi phím chuyển" opens the General pane, where the recorder lives (PRD-R40 screen 4).
@MainActor
protocol HotkeyRecorderPresenting: AnyObject {
    func presentHotkeyRecorder()
}
