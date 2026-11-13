// SPDX-License-Identifier: LicenseRef-App-Pending
//
// File-drop transport of the integration hooks (ADR 0502, "Integration hooks"). The harness writes
// `request-<sequence>.json` atomically into the hooks directory of the app under test; the INTEGRATION_HOOKS test
// build watches that directory (a vnode DispatchSource, no polling and no listening socket, PLT-R909), answers
// with `response-<sequence>.json` and never touches the request. The harness polls for the answer, then removes
// both files. Sequence numbers start at a random base per channel, and a response file already present for a new
// number is removed before the request is written, so an answer left behind by a killed harness process is never
// taken for the current run's (PLT-R821). Owner-only permissions (0700 directory, 0600 files) keep other users
// out. Runner only in practice; tests run it over InMemoryFileSystem with ManualClock.

public import AppModel
public import Diagnostics
public import Foundation
public import RealtimeSupport

public final class FileDropHookChannel: AppHookClient, Sendable {
    /// Directory name below the app's Application Support folder (`~/Library/Application Support/<folder>/`).
    public static let directoryName = IntegrationHookFiles.directoryName
    public static let defaultTimeoutNanoseconds: UInt64 = 10_000_000_000
    /// The latency probe types for several seconds per profile.
    public static let latencyProbeTimeoutNanoseconds: UInt64 = 120_000_000_000
    public static let pollIntervalNanoseconds: UInt64 = 50_000_000
    static let maximumResponseBytes = 4 << 20

    private let directory: URL
    private let fileSystem: any FileSystem
    private let clock: any MonotonicClock
    private let sleeper: any HarnessSleeper
    private let timeout: UInt64
    private let sequence: Mutex<UInt64>

    /// `firstSequence` is the number before the first request's; tests pass a fixed one.
    public init(
        directory: URL, fileSystem: any FileSystem, clock: any MonotonicClock, sleeper: any HarnessSleeper,
        timeoutNanoseconds: UInt64 = FileDropHookChannel.defaultTimeoutNanoseconds,
        firstSequence: UInt64 = FileDropHookChannel.randomSequenceBase()
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.clock = clock
        self.sleeper = sleeper
        self.timeout = timeoutNanoseconds
        self.sequence = Mutex(firstSequence)
    }

    /// A random multiple of 2^20 (at least 2^20, below 2^52): a channel sends far fewer than 2^20 requests, so two
    /// channels' numbers do not overlap unless their bases are equal (one chance in 2^32).
    public static func randomSequenceBase() -> UInt64 {
        UInt64.random(in: 1...UInt64(UInt32.max)) << 20
    }

    /// Removes every `request-*` and `response-*` file left in the hooks directory (an earlier run that was killed);
    /// other files and a missing directory are left alone.
    public func removeStaleFiles() {
        guard let files = try? fileSystem.contentsOfDirectory(at: directory) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("request-") || name.hasPrefix("response-") else { continue }
            try? fileSystem.removeItem(at: file)
        }
    }

    /// `<application support>/<folder>/IntegrationHooks`.
    public static func directory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    }

    public func requestURL(_ sequence: UInt64) -> URL {
        directory.appendingPathComponent(IntegrationHookFiles.requestName(sequence))
    }

    public func responseURL(_ sequence: UInt64) -> URL {
        directory.appendingPathComponent(IntegrationHookFiles.responseName(sequence))
    }

    public func send(_ command: AppHookCommand) async throws -> AppHookResponse {
        let number = sequence.withLock { value in
            value &+= 1
            return value
        }
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
        if fileSystem.fileExists(at: responseURL(number)) { try fileSystem.removeItem(at: responseURL(number)) }
        let request = try JSONEncoder().encode(AppHookRequest(sequence: number, command: command))
        try fileSystem.writeAtomically(request, to: requestURL(number), permissions: .ownerOnlyFile)
        defer {
            try? fileSystem.removeItem(at: requestURL(number))
            try? fileSystem.removeItem(at: responseURL(number))
        }
        let data = try await awaitResponse(number, command: command)
        guard let response = try? JSONDecoder().decode(AppHookResponse.self, from: data), response.sequence == number
        else { throw AppHookError.malformedResponse(command: command.name) }
        return response
    }

    private func awaitResponse(_ number: UInt64, command: AppHookCommand) async throws -> Data {
        let limit = command.name == "latencyProbe" ? max(timeout, Self.latencyProbeTimeoutNanoseconds) : timeout
        let deadline = clock.now().nanoseconds &+ limit
        while true {
            if fileSystem.fileExists(at: responseURL(number)) {
                return try fileSystem.readData(at: responseURL(number), maxBytes: Self.maximumResponseBytes)
            }
            guard clock.now().nanoseconds < deadline else { throw AppHookError.timeout(command: command.name) }
            try await sleeper.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }
}
