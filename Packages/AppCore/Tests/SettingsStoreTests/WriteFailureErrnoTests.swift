// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1006, PLT-R1202: a failed settings write keeps the POSIX errno in its notice, so the composition root logs
// the real code (`LogEvent.SettingsEvent.writeFailed`) instead of a placeholder. Workstream W5-B.

import AppModel
import Dispatch
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import SettingsStore

/// An in-memory file system whose atomic writes fail with a chosen errno (0 = they succeed).
private final class ErrnoFileSystem: FileSystem, Sendable {
    let base = InMemoryFileSystem()
    private let failure = Mutex<Int32>(0)

    func failWrites(with code: Int32) { failure.withLock { $0 = code } }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func readData(at url: URL, maxBytes: Int) throws -> Data { try base.readData(at: url, maxBytes: maxBytes) }
    func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        let code = failure.withLock { $0 }
        if code != 0 { throw FileSystemError.ioFailure(path: url.path, errno: code) }
        try base.writeAtomically(data, to: url, permissions: permissions)
    }
    func append(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        try base.append(data, to: url, permissions: permissions)
    }
    func createDirectory(at url: URL, permissions: FilePermissions) throws {
        try base.createDirectory(at: url, permissions: permissions)
    }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func attributes(at url: URL) throws -> FileAttributes { try base.attributes(at: url) }
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        try base.setExcludedFromBackup(excluded, at: url)
    }
}

@Suite struct WriteFailureErrnoTests {
    private let fileSystem = ErrnoFileSystem()
    private let scheduler = ManualScheduler(clock: ManualClock())
    private let store: SettingsStore

    init() {
        store = SettingsStore(
            location: StorageLocation(directory: URL(fileURLWithPath: "/Settings", isDirectory: true)),
            fileSystem: fileSystem, wallClock: FixedWallClock(), writtenBy: "0.1.0",
            queue: DispatchQueue(label: "write-failure-errno-tests", qos: .utility),
            launchGuard: LaunchGuard(store: InMemoryKeyValueStore()),
            scheduler: TimerDebounceScheduler(scheduler), onChange: { _ in })
    }

    private func change(_ method: TypingMethod) async {
        await store.updateSettings { $0.typingMethod = .set(method) }
        scheduler.advance(by: .seconds(1))
        _ = await store.state
    }

    @Test func theNoticeCarriesTheErrnoOfTheFailedWrite_PLTR1202() async {
        _ = await store.load()
        fileSystem.failWrites(with: ENOSPC)
        await change(.vni)
        #expect(await store.state.notices == [.writeFailed(.settings, errno: ENOSPC)])
    }

    /// One notice per file: a later failure with another errno replaces the first, and a successful write clears it.
    @Test func aLaterFailureReplacesTheNoticeAndASuccessClearsIt() async {
        _ = await store.load()
        fileSystem.failWrites(with: ENOSPC)
        await change(.vni)
        fileSystem.failWrites(with: EACCES)
        await change(.telex)
        #expect(await store.state.notices == [.writeFailed(.settings, errno: EACCES)])
        fileSystem.failWrites(with: 0)
        await change(.vni)
        #expect(await store.state.notices.isEmpty)
    }

    /// File-system errors map to their POSIX code; anything else (a serialisation error) has none and logs 0.
    @Test func errnoOfEveryFileSystemError() {
        struct Other: Error {}
        #expect(StoreNotice.errno(of: FileSystemError.ioFailure(path: "/x", errno: EROFS)) == EROFS)
        #expect(StoreNotice.errno(of: FileSystemError.notFound(path: "/x")) == ENOENT)
        #expect(StoreNotice.errno(of: FileSystemError.tooLarge(path: "/x", limit: 1)) == EFBIG)
        #expect(StoreNotice.errno(of: Other()) == StoreNotice.noErrno)
        #expect(StoreNotice.noErrno == 0)
    }
}
