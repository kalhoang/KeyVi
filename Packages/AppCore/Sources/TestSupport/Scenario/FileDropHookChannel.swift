// SPDX-License-Identifier: LicenseRef-App-Pending
//
// File-drop transport of the integration hooks (ADR 0502, "Integration hooks"). The harness writes
// `request-<sequence>.json` atomically into the hooks directory of the app under test; the INTEGRATION_HOOKS test
// build watches that directory (a vnode DispatchSource, no polling and no listening socket, PLT-R909), answers
// with `response-<sequence>.json` and never touches the request. The harness polls for the answer, then removes
// both files. Owner-only permissions (0700 directory, 0600 files) keep other users out. Runner only in practice;
// tests run it over InMemoryFileSystem with ManualClock.

public import AppModel
public import Foundation
public import RealtimeSupport
internal import Synchronization

public final class FileDropHookChannel: AppHookClient, Sendable {
    /// Directory name below the app's Application Support folder (`~/Library/Application Support/<folder>/`).
    public static let directoryName = "IntegrationHooks"
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
    private let sequence = Mutex<UInt64>(0)

    public init(
        directory: URL, fileSystem: any FileSystem, clock: any MonotonicClock, sleeper: any HarnessSleeper,
        timeoutNanoseconds: UInt64 = FileDropHookChannel.defaultTimeoutNanoseconds
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.clock = clock
        self.sleeper = sleeper
        self.timeout = timeoutNanoseconds
    }

    /// `<application support>/<folder>/IntegrationHooks`.
    public static func directory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    }

    public func requestURL(_ sequence: UInt64) -> URL {
        directory.appendingPathComponent("request-" + String(sequence) + ".json")
    }

    public func responseURL(_ sequence: UInt64) -> URL {
        directory.appendingPathComponent("response-" + String(sequence) + ".json")
    }

    public func send(_ command: AppHookCommand) async throws -> AppHookResponse {
        let number = sequence.withLock { value in
            value &+= 1
            return value
        }
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
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
