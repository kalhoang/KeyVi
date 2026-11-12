// SPDX-License-Identifier: LicenseRef-App-Pending

public import Foundation

/// POSIX permission bits. Every directory the app creates is 0700 and every file 0600 (PLT-R903, PLT-R1001).
public struct FilePermissions: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let ownerOnlyDirectory = FilePermissions(rawValue: 0o700)
    public static let ownerOnlyFile = FilePermissions(rawValue: 0o600)
}

public struct FileAttributes: Sendable, Hashable {
    public var size: Int
    public var modificationDate: Date
    public var creationDate: Date
    public var permissions: FilePermissions
    public init(size: Int, modificationDate: Date, creationDate: Date, permissions: FilePermissions) {
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.permissions = permissions
    }
}

public enum FileSystemError: Error, Sendable, Hashable {
    case notFound(path: String)
    case tooLarge(path: String, limit: Int)
    case ioFailure(path: String, errno: Int32)
}

/// File-system service used by SettingsStore and Diagnostics. The production implementation is
/// `LocalFileSystem`; tests use `InMemoryFileSystem` from TestSupport. Utility queue only: never called from
/// the tap, inject or ax threads (PLT-R203, PLT-R305).
public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    /// Reads at most `maxBytes`; larger files throw `.tooLarge` (PLT-R912 caps imports at 5 MB).
    func readData(at url: URL, maxBytes: Int) throws -> Data
    /// Temporary file in the same directory, `fsync`, then `rename` (PLT-R1003).
    func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws
    /// Appends to a log file, creating it with `permissions` if needed (PLT-R903 JSON lines).
    func append(_ data: Data, to url: URL, permissions: FilePermissions) throws
    func createDirectory(at url: URL, permissions: FilePermissions) throws
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func attributes(at url: URL) throws -> FileAttributes
    /// `URLResourceValues.isExcludedFromBackup` (PLT-R905 captures).
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws
}

/// Wall-clock time for timestamps in files and reports. Monotonic time for the hot path lives in
/// RealtimeSupport (`MonotonicClock`).
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Production file system: Foundation plus POSIX calls for permissions, `fsync` and atomic `rename`.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func readData(at url: URL, maxBytes: Int) throws -> Data {
        let attributes = try attributes(at: url)
        guard attributes.size <= maxBytes else { throw FileSystemError.tooLarge(path: url.path, limit: maxBytes) }
        do {
            return try Data(contentsOf: url, options: [.uncached])
        } catch {
            throw FileSystemError.ioFailure(path: url.path, errno: EIO)
        }
    }

    public func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions.rawValue))
        guard descriptor >= 0 else { throw FileSystemError.ioFailure(path: temporary.path, errno: errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, failure == 0 {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { failure = errno } else { offset += written }
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        guard failure == 0 else {
            unlink(temporary.path)
            throw FileSystemError.ioFailure(path: url.path, errno: failure)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw FileSystemError.ioFailure(path: url.path, errno: code)
        }
    }

    public func append(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(permissions.rawValue))
        guard descriptor >= 0 else { throw FileSystemError.ioFailure(path: url.path, errno: errno) }
        defer { close(descriptor) }
        let failed = data.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count) != buffer.count
        }
        if failed { throw FileSystemError.ioFailure(path: url.path, errno: errno) }
    }

    public func createDirectory(at url: URL, permissions: FilePermissions) throws {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: permissions.rawValue)])
            guard chmod(url.path, mode_t(permissions.rawValue)) == 0 else {
                throw FileSystemError.ioFailure(path: url.path, errno: errno)
            }
        } catch let error as FileSystemError {
            throw error
        } catch {
            throw FileSystemError.ioFailure(path: url.path, errno: EIO)
        }
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw FileSystemError.ioFailure(path: source.path, errno: errno)
        }
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw FileSystemError.ioFailure(path: destination.path, errno: EIO)
        }
    }

    public func removeItem(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FileSystemError.notFound(path: url.path)
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            throw FileSystemError.notFound(path: url.path)
        }
    }

    public func attributes(at url: URL) throws -> FileAttributes {
        let values: [FileAttributeKey: Any]
        do {
            values = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FileSystemError.notFound(path: url.path)
        }
        return FileAttributes(
            size: (values[.size] as? NSNumber)?.intValue ?? 0,
            modificationDate: values[.modificationDate] as? Date ?? .distantPast,
            creationDate: values[.creationDate] as? Date ?? .distantPast,
            permissions: FilePermissions(rawValue: (values[.posixPermissions] as? NSNumber)?.uint16Value ?? 0))
    }

    public func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = excluded
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            throw FileSystemError.ioFailure(path: url.path, errno: EIO)
        }
    }
}
