// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings fakes (workstream W1-B): a debounce adapter over `ManualScheduler`, a file system spy with fault
// injection, a change recorder and a harness that wires a `SettingsStore` to all of them, so store behaviour
// (debounce, recovery, safe mode, export/import) is tested in virtual time without touching the disk.

public import AppModel
internal import Dispatch
public import Foundation
public import RealtimeSupport
public import SettingsStore

/// `DebounceScheduler` over any `TimerScheduler` (tests: `ManualScheduler`, ADR 0313).
public struct TimerDebounceScheduler: DebounceScheduler {
    public let base: any TimerScheduler

    public init(_ base: any TimerScheduler) { self.base = base }

    public func schedule(after delay: TimeSpan, _ handler: @escaping @Sendable () -> Void) -> any DebounceTimer {
        TimerBox(timer: base.schedule(after: delay, leeway: .milliseconds(100), handler))
    }

    private struct TimerBox: DebounceTimer {
        let timer: any ScheduledTimer
        func cancel() { timer.cancel() }
    }
}

/// Wraps a `FileSystem`, records every call in order and can make chosen calls fail.
public final class SpyFileSystem: FileSystem, Sendable {
    public enum Operation: String, Sendable, Hashable, CaseIterable {
        case fileExists, readData, writeAtomically, append, createDirectory, moveItem, copyItem, removeItem,
            contentsOfDirectory, attributes, setExcludedFromBackup
    }

    public struct Call: Sendable, Hashable {
        public var operation: Operation
        public var path: String
        public var destination: String?
    }

    public let base: any FileSystem
    private let log = Mutex<[Call]>([])
    private let failures = Mutex<Set<String>>([])

    public init(_ base: any FileSystem) { self.base = base }

    public var calls: [Call] { log.withLock { $0 } }
    public func resetCalls() { log.withLock { $0.removeAll() } }

    /// Calls that change the disk (write, append, create, move, copy, remove).
    public var mutatingCalls: [Call] {
        let mutating: Set<Operation> = [.writeAtomically, .append, .createDirectory, .moveItem, .copyItem, .removeItem]
        return calls.filter { mutating.contains($0.operation) }
    }

    /// Every `operation` on `url` fails with EIO until `clearFailures()`.
    public func fail(_ operation: Operation, at url: URL) {
        _ = failures.withLock { $0.insert(Self.key(operation, url.path)) }
    }

    /// Every `operation` on any path fails.
    public func failAll(_ operation: Operation) { _ = failures.withLock { $0.insert(Self.key(operation, "*")) } }

    public func clearFailures() { failures.withLock { $0.removeAll() } }

    public func fileExists(at url: URL) -> Bool {
        record(.fileExists, url)
        return base.fileExists(at: url)
    }

    public func readData(at url: URL, maxBytes: Int) throws -> Data {
        try check(.readData, url)
        return try base.readData(at: url, maxBytes: maxBytes)
    }

    public func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        try check(.writeAtomically, url)
        try base.writeAtomically(data, to: url, permissions: permissions)
    }

    public func append(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        try check(.append, url)
        try base.append(data, to: url, permissions: permissions)
    }

    public func createDirectory(at url: URL, permissions: FilePermissions) throws {
        try check(.createDirectory, url)
        try base.createDirectory(at: url, permissions: permissions)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try check(.moveItem, source, destination: destination)
        try base.moveItem(at: source, to: destination)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try check(.copyItem, source, destination: destination)
        try base.copyItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try check(.removeItem, url)
        try base.removeItem(at: url)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try check(.contentsOfDirectory, url)
        return try base.contentsOfDirectory(at: url)
    }

    public func attributes(at url: URL) throws -> FileAttributes {
        try check(.attributes, url)
        return try base.attributes(at: url)
    }

    public func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        try check(.setExcludedFromBackup, url)
        try base.setExcludedFromBackup(excluded, at: url)
    }

    private func record(_ operation: Operation, _ url: URL, destination: URL? = nil) {
        log.withLock { $0.append(Call(operation: operation, path: url.path, destination: destination?.path)) }
    }

    private func check(_ operation: Operation, _ url: URL, destination: URL? = nil) throws {
        record(operation, url, destination: destination)
        let failing = failures.withLock {
            $0.contains(Self.key(operation, url.path)) || $0.contains(Self.key(operation, "*"))
        }
        if failing { throw FileSystemError.ioFailure(path: url.path, errno: EIO) }
    }

    private static func key(_ operation: Operation, _ path: String) -> String { operation.rawValue + "|" + path }
}

/// Collects every published `SettingsState` (the store calls `onChange` on its queue).
public final class SettingsChangeRecorder: Sendable {
    private let states = Mutex<[SettingsState]>([])

    public init() {}

    public var all: [SettingsState] { states.withLock { $0 } }
    public var last: SettingsState? { states.withLock { $0.last } }
    public var count: Int { states.withLock { $0.count } }

    public func record(_ state: SettingsState) { states.withLock { $0.append(state) } }
}

/// A `SettingsStore` over in-memory fakes. Files live under `/Settings` in `memory`; `spy` sees every call.
public struct SettingsStoreHarness: Sendable {
    public static let directory = URL(fileURLWithPath: "/Settings", isDirectory: true)

    public let memory: InMemoryFileSystem
    public let spy: SpyFileSystem
    public let wallClock: FixedWallClock
    public let clock: ManualClock
    public let scheduler: ManualScheduler
    public let keyValues: InMemoryKeyValueStore
    public let launchGuard: LaunchGuard
    public let recorder: SettingsChangeRecorder
    public let location: StorageLocation
    public let store: SettingsStore

    /// A new store over the same files and key-value store as `previous` (the next launch), or over fresh ones.
    public init(
        reusing previous: SettingsStoreHarness? = nil, writtenBy: String = "0.1.0",
        migrations: MigrationChain = .shipped
    ) {
        memory = previous?.memory ?? InMemoryFileSystem()
        spy = SpyFileSystem(memory)
        wallClock = previous?.wallClock ?? FixedWallClock()
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        keyValues = previous?.keyValues ?? InMemoryKeyValueStore()
        launchGuard = LaunchGuard(store: keyValues)
        recorder = SettingsChangeRecorder()
        location = StorageLocation(directory: Self.directory)
        let recorder = recorder
        store = SettingsStore(
            location: location, fileSystem: spy, wallClock: wallClock, writtenBy: writtenBy,
            queue: DispatchQueue(label: "settings-store-tests", qos: .utility), migrations: migrations,
            launchGuard: launchGuard, scheduler: TimerDebounceScheduler(scheduler),
            onChange: { recorder.record($0) })
    }

    /// Advances virtual time, then waits until the store has run every write the timers queued.
    public func advance(by duration: TimeSpan) async {
        scheduler.advance(by: duration)
        _ = await store.state
    }

    public func url(_ file: SettingsFile) -> URL { location.url(for: file) }

    /// Current bytes of `file`, nil when absent.
    public func data(_ file: SettingsFile) -> Data? { memory.nodes[url(file).path]?.data }

    /// Parsed JSON object of `file`, nil when absent or unreadable.
    public func object(_ file: SettingsFile) -> [String: JSONValue]? {
        guard let data = data(file), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return value.objectValue
    }

    /// Writes `text` as `file` with 0600, creating the folder (0700) first.
    public func seed(_ file: SettingsFile, _ text: String) {
        try? memory.createDirectory(at: Self.directory, permissions: .ownerOnlyDirectory)
        try? memory.writeAtomically(Data(text.utf8), to: url(file), permissions: .ownerOnlyFile)
    }

    /// Paths below the settings folder (relative), sorted.
    public var paths: [String] {
        let prefix = Self.directory.path + "/"
        return memory.nodes.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }
}
