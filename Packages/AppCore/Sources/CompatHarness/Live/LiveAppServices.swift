// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The app under test on the self-hosted runner: start and stop it (AppConfigurator), the files and unified log it
// wrote (privacy canary, section 9), its network connections (egress, 13.7). Runner only: never constructed in a
// dry run, never run by tests or on a developer Mac (workstreams.md rule 5).

import AppKit
import AppModel
import Darwin
import Foundation
import RealtimeSupport
import TestSupport

struct LiveAppControl: AppUnderTestControl {
    static let quitTimeoutNanoseconds: UInt64 = 10_000_000_000
    let app: BundleKey
    let sleeper: any HarnessSleeper

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.rawValue).first
    }

    func isRunning() -> Bool { running != nil }

    func processIdentifier() -> Int32? { running?.processIdentifier }

    /// Normal quit (the app flushes its settings, PLT-R1003), then waits until the process is gone.
    func quit() async throws {
        guard let running else { return }
        running.terminate()
        var waited: UInt64 = 0
        while !running.isTerminated {
            guard waited < Self.quitTimeoutNanoseconds else { throw LiveError.unsupported("quit of " + app.rawValue) }
            try await sleeper.sleep(nanoseconds: 100_000_000)
            waited += 100_000_000
        }
    }

    func launch() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else {
            throw LiveError.appNotFound(app.rawValue)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

/// Files below the app's own folders and its unified-log output since creation (PLT-R901, PLT-R903, PLT-R905).
struct LivePrivacyEvidence: PrivacyEvidenceSource {
    let library: URL
    let folder: String
    let app: BundleKey
    let start = Date()

    /// Application Support and Logs folders (without `Logs/<folder>/captures`), preferences, caches, HTTP
    /// storage and saved state of the bundle.
    func appWrittenFiles() throws -> [URL] {
        let logs = library.appendingPathComponent("Logs/" + folder, isDirectory: true)
        let roots = [
            library.appendingPathComponent("Application Support/" + folder, isDirectory: true), logs,
            library.appendingPathComponent("Preferences/" + app.rawValue + ".plist"),
            library.appendingPathComponent("Caches/" + app.rawValue, isDirectory: true),
            library.appendingPathComponent("HTTPStorages/" + app.rawValue, isDirectory: true),
            library.appendingPathComponent(
                "Saved Application State/" + app.rawValue + ".savedState", isDirectory: true),
        ]
        let captures = logs.appendingPathComponent("captures", isDirectory: true).standardizedFileURL.path + "/"
        return roots.flatMap(Self.regularFiles).filter { !$0.standardizedFileURL.path.hasPrefix(captures) }
    }

    func unifiedLog() async throws -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue),
            let executable = Bundle(url: url)?.executableURL?.lastPathComponent
        else { throw LiveError.appNotFound(app.rawValue) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let predicate = "process == \"" + executable.replacingOccurrences(of: "\"", with: "") + "\""
        return try ProcessRunner.output(
            "/usr/bin/log",
            [
                "show", "--style", "ndjson", "--info", "--debug", "--start", formatter.string(from: start),
                "--predicate", predicate,
            ])
    }

    static func regularFiles(_ root: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [root] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }
    }
}

/// lsof sampling and DNS for the egress test.
struct LiveConnectionSampler: ConnectionSampler {
    func remoteEndpoints(processIdentifier: Int32) async throws -> [EgressEndpoint] {
        guard kill(processIdentifier, 0) == 0 else { throw LiveError.appNotRunning(String(processIdentifier)) }
        // lsof exits 1 when the process has no internet socket: that is an empty sample, not an error.
        let output = try ProcessRunner.output(
            "/usr/sbin/lsof", ["-nP", "-a", "-p", String(processIdentifier), "-i", "-F", "pPn"],
            allowedStatuses: [0, 1])
        return LsofOutput.remoteEndpoints(output)
    }

    func addresses(of host: String) async -> Set<String> {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
            ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var addresses = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                NI_NUMERICHOST)
                == 0
            {
                addresses.insert(
                    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return addresses
    }
}

/// Runs a tool and returns its standard output (runner only: `log`, `lsof`).
enum ProcessRunner {
    static func output(_ path: String, _ arguments: [String], allowedStatuses: Set<Int32> = [0]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowedStatuses.contains(process.terminationStatus) else {
            throw LiveError.unsupported(path + " exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
