// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W3-A: the hooks directory on a real file system (a fresh temporary directory per test, removed afterwards):
// 0700 directory, 0600 atomic answers, refusal of links, other users' files, non-regular files and oversized
// requests, and the vnode watcher (ADR 0502, "Integration hooks"; PLT-R909: no polling, no socket).

import Diagnostics
import Foundation
import Synchronization
import Testing

@testable import InputHost

/// A temporary directory that holds the hooks directory; removed when the test ends.
private final class Scratch {
    let root: URL
    let hooks: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hooks-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        hooks = PosixHookDirectory.directory(applicationSupport: root.appendingPathComponent("App Support"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: hooks.appendingPathComponent(name))
    }
}

@Suite struct PosixHookDirectoryTests {
    @Test func prepareCreatesAnOwnerOnlyDirectory() throws {
        let scratch = try Scratch()
        let directory = PosixHookDirectory(directory: scratch.hooks)
        try directory.prepare()
        #expect(try scratch.mode(scratch.hooks) == 0o700)
        #expect(scratch.hooks.lastPathComponent == "IntegrationHooks")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.hooks.path)
        try directory.prepare()  // an existing directory is tightened
        #expect(try scratch.mode(scratch.hooks) == 0o700)
    }

    @Test func prepareRefusesALinkAFileAndAnotherUsersDirectory() throws {
        let scratch = try Scratch()
        let elsewhere = scratch.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scratch.hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.hooks, withDestinationURL: elsewhere)
        #expect(throws: HookDirectoryError.symbolicLink) { try PosixHookDirectory(directory: scratch.hooks).prepare() }
        try FileManager.default.removeItem(at: scratch.hooks)
        try Data().write(to: scratch.hooks)
        #expect(throws: HookDirectoryError.notDirectory) { try PosixHookDirectory(directory: scratch.hooks).prepare() }
        try FileManager.default.removeItem(at: scratch.hooks)
        let stranger = PosixHookDirectory(directory: scratch.hooks, userID: getuid() &+ 1)
        #expect(throws: HookDirectoryError.foreignOwner) { try stranger.prepare() }
    }

    @Test func listsOnlyRequestFiles() throws {
        let scratch = try Scratch()
        let directory = PosixHookDirectory(directory: scratch.hooks)
        try directory.prepare()
        for name in ["request-9.json", "request-10.json", "response-9.json", ".request-11.json.X.tmp", "notes.txt"] {
            try scratch.write(name, "{}")
        }
        #expect(directory.requestSequences() == [9, 10])
        #expect(directory.responseExists(9) && !directory.responseExists(10))
    }

    @Test func readsARegularFileOfTheUser() throws {
        let scratch = try Scratch()
        let directory = PosixHookDirectory(directory: scratch.hooks)
        try directory.prepare()
        try scratch.write("request-3.json", #"{"command":"state"}"#)
        #expect(try directory.readRequest(3, maxBytes: 4_096).get() == Data(#"{"command":"state"}"#.utf8))
        #expect(directory.readRequest(4, maxBytes: 4_096) == .failure(.missing))
        #expect(directory.readRequest(3, maxBytes: 5) == .failure(.tooLarge))
        let stranger = PosixHookDirectory(directory: scratch.hooks, userID: getuid() &+ 1)
        #expect(stranger.readRequest(3, maxBytes: 4_096) == .failure(.foreignOwner))
    }

    @Test func refusesLinksAndNonRegularFiles() throws {
        let scratch = try Scratch()
        let directory = PosixHookDirectory(directory: scratch.hooks)
        try directory.prepare()
        let target = scratch.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: scratch.hooks.appendingPathComponent("request-1.json"), withDestinationURL: target)
        #expect(directory.readRequest(1, maxBytes: 4_096) == .failure(.symbolicLink))
        try FileManager.default.createDirectory(
            at: scratch.hooks.appendingPathComponent("request-2.json"), withIntermediateDirectories: false)
        #expect(directory.readRequest(2, maxBytes: 4_096) == .failure(.notRegularFile))
        #expect(mkfifo(scratch.hooks.appendingPathComponent("request-3.json").path, 0o600) == 0)
        #expect(directory.readRequest(3, maxBytes: 4_096) == .failure(.notRegularFile), "a FIFO never blocks")
    }

    /// Answers are written atomically with mode 0600 and no temporary file left behind; a second write replaces.
    @Test func writesAnswersAtomicallyOwnerOnly() throws {
        let scratch = try Scratch()
        let directory = PosixHookDirectory(directory: scratch.hooks)
        try directory.prepare()
        try directory.writeResponse(Data(#"{"ok":true}"#.utf8), sequence: 42)
        let answer = scratch.hooks.appendingPathComponent("response-42.json")
        #expect(try Data(contentsOf: answer) == Data(#"{"ok":true}"#.utf8))
        #expect(try scratch.mode(answer) == 0o600)
        try directory.writeResponse(Data(#"{"ok":false}"#.utf8), sequence: 42)
        #expect(try Data(contentsOf: answer) == Data(#"{"ok":false}"#.utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.hooks.path)
        #expect(names == ["response-42.json"])
        let missing = PosixHookDirectory(directory: scratch.root.appendingPathComponent("absent"))
        #expect(throws: HookDirectoryError.self) { try missing.writeResponse(Data(), sequence: 1) }
    }
}

@Suite struct VnodeDirectoryWatcherTests {
    private final class Events: Sendable {
        let changes = Mutex<[DirectoryChange]>([])
        let signal = DispatchSemaphore(value: 0)
        func record(_ change: DirectoryChange) {
            changes.withLock { $0.append(change) }
            signal.signal()
        }
        func wait() -> Bool { signal.wait(timeout: .now() + 5) == .success }
    }

    /// A new entry is reported without polling; deleting the directory reports `.replaced`; after `stop`
    /// nothing is reported.
    @Test func reportsChangesFromTheKernel() throws {
        let scratch = try Scratch()
        try PosixHookDirectory(directory: scratch.hooks).prepare()
        let watcher = VnodeDirectoryWatcher(
            directory: scratch.hooks, queue: DispatchQueue(label: "test.hooks.watcher"))
        let events = Events()
        try watcher.start { events.record($0) }
        try scratch.write("request-1.json", "{}")
        #expect(events.wait())
        #expect(events.changes.withLock { $0.first } == .contents)
        try FileManager.default.removeItem(at: scratch.hooks)
        var replaced = false
        while !replaced, events.wait() { replaced = events.changes.withLock { $0.contains(.replaced) } }
        #expect(replaced)
        watcher.stop()
        while events.signal.wait(timeout: .now() + 0.1) == .success {}  // events queued before the stop
        try PosixHookDirectory(directory: scratch.hooks).prepare()
        let before = events.changes.withLock { $0.count }
        try scratch.write("request-2.json", "{}")
        #expect(events.signal.wait(timeout: .now() + 0.3) == .timedOut)
        #expect(events.changes.withLock { $0.count } == before)
    }

    @Test func refusesALinkedDirectory() throws {
        let scratch = try Scratch()
        let elsewhere = scratch.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = scratch.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let watcher = VnodeDirectoryWatcher(directory: link, queue: DispatchQueue(label: "test.hooks.link"))
        #expect(throws: HookDirectoryError.symbolicLink) { try watcher.start { _ in } }
    }
}
