// SPDX-License-Identifier: GPL-3.0-or-later
//
// The hooks directory of the INTEGRATION_HOOKS test build (ADR 0502, "Integration hooks"):
// `~/Library/Application Support/<storage folder>/IntegrationHooks/`, 0700, requests and responses 0600. The app
// reads `request-<n>.json` and writes `response-<n>.json` atomically (temporary file, fsync, rename); it never
// deletes either file (the harness does). Symbolic links, files of another user and non-regular files are refused
// without being opened for reading content; requests are capped in size. File I/O on the hooks queue only, never
// on the tap, inject or ax threads (PLT-R203, PLT-R305).

internal import Diagnostics
public import Foundation

/// Why a request file was not read.
public enum HookFileRefusal: Error, Sendable, Hashable {
    /// Gone between the listing and the read (the harness removed it).
    case missing
    case symbolicLink
    case notRegularFile
    /// Owned by another user.
    case foreignOwner
    case tooLarge
    case unreadable(errno: Int32)
}

/// Why the hooks directory cannot be used; the app then does not answer hooks at all.
public enum HookDirectoryError: Error, Sendable, Hashable {
    case symbolicLink
    case notDirectory
    case foreignOwner
    case io(errno: Int32)
}

/// What the hooks server needs from the directory. Production: `PosixHookDirectory`; tests: an in-memory fake.
public protocol IntegrationHookFileAccess: Sendable {
    /// Creates the directory (0700) or checks the existing one: a real directory of the current user, tightened to
    /// 0700.
    func prepare() throws(HookDirectoryError)
    /// Sequence numbers of the `request-<n>.json` files present, ascending.
    func requestSequences() -> [UInt64]
    /// The request's bytes: a regular file of the current user, at most `maxBytes`.
    func readRequest(_ sequence: UInt64, maxBytes: Int) -> Result<Data, HookFileRefusal>
    func responseExists(_ sequence: UInt64) -> Bool
    /// `response-<n>.json`, 0600, written atomically.
    func writeResponse(_ data: Data, sequence: UInt64) throws(HookDirectoryError)
}

/// POSIX implementation: `lstat`, `open(O_NOFOLLOW | O_NONBLOCK)` with `fstat` on the open descriptor (so a file
/// swapped for a link after the listing is still refused), and `rename` for atomic answers.
public struct PosixHookDirectory: IntegrationHookFileAccess {
    public let directory: URL
    private let userID: uid_t

    public init(directory: URL, userID: uid_t = getuid()) {
        self.directory = directory
        self.userID = userID
    }

    /// `<application support>/<storage folder>/IntegrationHooks`.
    public static func directory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(IntegrationHookFiles.directoryName, isDirectory: true)
    }

    public func prepare() throws(HookDirectoryError) {
        let parent = directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } catch {
            throw .io(errno: EIO)
        }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw .io(errno: errno) }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw .io(errno: errno) }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK { throw .symbolicLink }
        guard kind == S_IFDIR else { throw .notDirectory }
        guard info.st_uid == userID else { throw .foreignOwner }
        if info.st_mode & 0o777 != 0o700, chmod(directory.path, 0o700) != 0 { throw .io(errno: errno) }
    }

    public func requestSequences() -> [UInt64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(IntegrationHookFiles.requestSequence(fileName:)).sorted()
    }

    public func readRequest(_ sequence: UInt64, maxBytes: Int) -> Result<Data, HookFileRefusal> {
        let path = directory.appendingPathComponent(IntegrationHookFiles.requestName(sequence)).path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ELOOP: return .failure(.symbolicLink)
            case ENOENT: return .failure(.missing)
            case let code: return .failure(.unreadable(errno: code))
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(.unreadable(errno: errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_uid == userID else { return .failure(.foreignOwner) }
        guard info.st_size <= off_t(maxBytes) else { return .failure(.tooLarge) }
        return Self.readAll(descriptor, maxBytes: maxBytes)
    }

    public func responseExists(_ sequence: UInt64) -> Bool {
        var info = stat()
        return lstat(directory.appendingPathComponent(IntegrationHookFiles.responseName(sequence)).path, &info) == 0
    }

    public func writeResponse(_ data: Data, sequence: UInt64) throws(HookDirectoryError) {
        let final = directory.appendingPathComponent(IntegrationHookFiles.responseName(sequence)).path
        let temporary = directory.appendingPathComponent(
            "." + IntegrationHookFiles.responseName(sequence) + "." + UUID().uuidString + ".tmp"
        ).path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .io(errno: errno) }
        var failure = fchmod(descriptor, 0o600) == 0 ? 0 : errno
        if failure == 0 { failure = Self.writeAll(data, to: descriptor) }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, rename(temporary, final) != 0 { failure = errno }
        guard failure == 0 else {
            unlink(temporary)
            throw .io(errno: failure)
        }
    }

    /// Reads to the end; more than `maxBytes` (a file that grew after `fstat`) is `.tooLarge`.
    private static func readAll(_ descriptor: Int32, maxBytes: Int) -> Result<Data, HookFileRefusal> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { return .failure(.unreadable(errno: errno)) }
            if count == 0 { return .success(data) }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maxBytes { return .failure(.tooLarge) }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32 {
        data.withUnsafeBytes { buffer -> Int32 in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { return errno }
                offset += written
            }
            return 0
        }
    }
}

/// Watches a directory for changes to its entries with a vnode `DispatchSource` (no polling, no socket, no
/// distributed notification; PLT-R909). Production: `VnodeDirectoryWatcher`; tests drive the server directly.
public protocol DirectoryChangeWatching: AnyObject, Sendable {
    /// Starts delivering `onChange` on the watcher's queue: `.contents` when entries were added, removed or
    /// renamed, `.replaced` when the directory itself was deleted or renamed (the server prepares it again).
    func start(onChange: @escaping @Sendable (DirectoryChange) -> Void) throws(HookDirectoryError)
    func stop()
}

public enum DirectoryChange: Sendable, Hashable {
    case contents
    case replaced
}

public final class VnodeDirectoryWatcher: DirectoryChangeWatching, Sendable {
    private let directory: URL
    private let queue: DispatchQueue
    private let source = SourceBox()

    /// The live source; replaced on every `start`, cancelled on `stop`.
    private final class SourceBox: @unchecked Sendable {
        // @unchecked: every access holds `lock`; DispatchSource itself is thread-safe to cancel.
        private let lock = NSLock()
        private var current: (any DispatchSourceFileSystemObject)?

        func replace(with next: (any DispatchSourceFileSystemObject)?) {
            lock.lock()
            let previous = current
            current = next
            lock.unlock()
            previous?.cancel()
        }
    }

    public init(directory: URL, queue: DispatchQueue) {
        self.directory = directory
        self.queue = queue
    }

    deinit { source.replace(with: nil) }

    public func start(onChange: @escaping @Sendable (DirectoryChange) -> Void) throws(HookDirectoryError) {
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ELOOP ? .symbolicLink : .io(errno: errno) }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        watcher.setEventHandler { [weak watcher] in
            guard let events = watcher?.data else { return }
            onChange(events.isDisjoint(with: [.delete, .rename, .revoke]) ? .contents : .replaced)
        }
        watcher.setCancelHandler { close(descriptor) }
        source.replace(with: watcher)
        watcher.resume()
    }

    public func stop() { source.replace(with: nil) }
}
