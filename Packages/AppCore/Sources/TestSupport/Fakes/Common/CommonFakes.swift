// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared fakes provided by the skeleton so every wave-1 workstream can test immediately.

public import AppModel
public import Foundation
public import RealtimeSupport
public import SettingsStore
internal import Synchronization

/// In-memory `FileSystem` with POSIX-like permissions and atomic writes. Supports fault injection.
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {
    public struct Node: Sendable, Hashable {
        public var data: Data?  // nil = directory
        public var permissions: FilePermissions
        public var modified: Date
        public var created: Date
        public var excludedFromBackup: Bool
    }

    private let state = Mutex<[String: Node]>([:])
    private let now: @Sendable () -> Date
    private let failingWrites = Mutex<Set<String>>([])

    public init(now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) {
        self.now = now
    }

    public var nodes: [String: Node] { state.withLock { $0 } }

    /// The next write to `url` fails (corruption and failure tests, PLT-R1006).
    public func failNextWrite(to url: URL) { _ = failingWrites.withLock { $0.insert(url.path) } }

    public func fileExists(at url: URL) -> Bool { state.withLock { $0[url.path] != nil } }

    public func readData(at url: URL, maxBytes: Int) throws -> Data {
        guard let node = state.withLock({ $0[url.path] }), let data = node.data else {
            throw FileSystemError.notFound(path: url.path)
        }
        guard data.count <= maxBytes else { throw FileSystemError.tooLarge(path: url.path, limit: maxBytes) }
        return data
    }

    public func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        if failingWrites.withLock({ $0.remove(url.path) }) != nil {
            throw FileSystemError.ioFailure(path: url.path, errno: EIO)
        }
        let date = now()
        state.withLock {
            let created = $0[url.path]?.created ?? date
            $0[url.path] = Node(
                data: data, permissions: permissions, modified: date, created: created, excludedFromBackup: false)
        }
    }

    public func append(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        let date = now()
        state.withLock {
            var node =
                $0[url.path]
                ?? Node(data: Data(), permissions: permissions, modified: date, created: date, excludedFromBackup: false)
            node.data = (node.data ?? Data()) + data
            node.modified = date
            $0[url.path] = node
        }
    }

    public func createDirectory(at url: URL, permissions: FilePermissions) throws {
        let date = now()
        state.withLock {
            $0[url.path] = Node(data: nil, permissions: permissions, modified: date, created: date, excludedFromBackup: false)
        }
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try state.withLock {
            guard let node = $0.removeValue(forKey: source.path) else { throw FileSystemError.notFound(path: source.path) }
            $0[destination.path] = node
        }
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try state.withLock {
            guard let node = $0[source.path] else { throw FileSystemError.notFound(path: source.path) }
            $0[destination.path] = node
        }
    }

    public func removeItem(at url: URL) throws {
        try state.withLock {
            guard $0.removeValue(forKey: url.path) != nil else { throw FileSystemError.notFound(path: url.path) }
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return state.withLock { nodes in
            nodes.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
                .sorted().map { URL(fileURLWithPath: $0) }
        }
    }

    public func attributes(at url: URL) throws -> FileAttributes {
        guard let node = state.withLock({ $0[url.path] }) else { throw FileSystemError.notFound(path: url.path) }
        return FileAttributes(
            size: node.data?.count ?? 0, modificationDate: node.modified, creationDate: node.created,
            permissions: node.permissions)
    }

    public func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        try state.withLock {
            guard $0[url.path] != nil else { throw FileSystemError.notFound(path: url.path) }
            $0[url.path]?.excludedFromBackup = excluded
        }
    }
}

/// Virtual monotonic clock. `sleep(until:)` advances virtual time instead of blocking.
public final class ManualClock: MonotonicClock, Sendable {
    private let nanos: Atomic<UInt64>
    public init(start: MonotonicInstant = MonotonicInstant(nanoseconds: 1_000_000_000)) {
        nanos = Atomic(start.nanoseconds)
    }

    public func now() -> MonotonicInstant { MonotonicInstant(nanoseconds: nanos.load(ordering: .sequentiallyConsistent)) }

    public func sleep(until deadline: MonotonicInstant) {
        var current = nanos.load(ordering: .sequentiallyConsistent)
        while current < deadline.nanoseconds {
            let (exchanged, original) = nanos.compareExchange(
                expected: current, desired: deadline.nanoseconds, ordering: .sequentiallyConsistent)
            if exchanged { return }
            current = original
        }
    }

    public func advance(byMicroseconds microseconds: UInt64) {
        nanos.wrappingAdd(microseconds * 1_000, ordering: .sequentiallyConsistent)
    }
}

public final class FixedWallClock: WallClock, Sendable {
    private let seconds: Mutex<Double>
    public init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        seconds = Mutex(date.timeIntervalSince1970)
    }

    public func now() -> Date { Date(timeIntervalSince1970: seconds.withLock { $0 }) }
    public func advance(by interval: TimeInterval) { seconds.withLock { $0 += interval } }
}

public final class InMemoryKeyValueStore: KeyValueStore, Sendable {
    private let values = Mutex<[String: Double]>([:])
    public init() {}
    public func integer(forKey key: String) -> Int { Int(values.withLock { $0[key] ?? 0 }) }
    public func set(_ value: Int, forKey key: String) { values.withLock { $0[key] = Double(value) } }
    public func double(forKey key: String) -> Double { values.withLock { $0[key] ?? 0 } }
    public func set(_ value: Double, forKey key: String) { values.withLock { $0[key] = value } }
}
