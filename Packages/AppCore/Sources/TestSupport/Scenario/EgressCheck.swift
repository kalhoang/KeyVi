// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Network egress test (02-platform.md 13.7, PLT-R906, PLT-R504): for N minutes, sample the open internet sockets
// of the app under test once per interval (`lsof -nP -a -p <pid> -i -F pPn`, no root needed for the runner's own
// processes) and classify every remote endpoint. Phase `local` (feed pointed at a local appcast): only loopback is
// allowed. Phase `production`: loopback plus the current addresses of the allowed hosts (the site host from
// scripts/brand.env, resolved at every sample because CDN addresses rotate). A forced update check is requested at
// the start through the integration hooks when the app answers them. Sampling and DNS are live services; the
// parsing and the verdict are here and tested.

internal import Foundation

public struct EgressEndpoint: Sendable, Hashable, Codable, Comparable {
    public var address: String
    public var port: Int
    /// `TCP` or `UDP` (lsof field `P`).
    public var transport: String

    public init(address: String, port: Int, transport: String) {
        self.address = address
        self.port = port
        self.transport = transport
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.address, lhs.port, lhs.transport) < (rhs.address, rhs.port, rhs.transport)
    }

    /// 127.0.0.0/8, ::1 and IPv4-mapped loopback.
    public var isLoopback: Bool {
        address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.")
    }
}

/// Parses `lsof -F pPn` output: remote ends of connected sockets (`n<local>-><remote>`).
public enum LsofOutput {
    public static func remoteEndpoints(_ output: String) -> [EgressEndpoint] {
        var transport = "TCP"
        var endpoints: [EgressEndpoint] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "P": transport = value
            case "n":
                guard let arrow = value.range(of: "->"), let endpoint = endpoint(String(value[arrow.upperBound...]))
                else { continue }
                endpoints.append(EgressEndpoint(address: endpoint.0, port: endpoint.1, transport: transport))
            default: continue
            }
        }
        return endpoints
    }

    /// `17.1.2.3:443` or `[2001:db8::1]:443`.
    static func endpoint(_ text: String) -> (String, Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }
}

public enum EgressPhase: String, Sendable, Hashable, Codable, CaseIterable {
    /// Feed pointed at a local appcast: loopback only.
    case local
    /// Production feed: loopback and the allowed hosts.
    case production
}

/// Live sampling (CompatHarness/Live): lsof of one process and DNS resolution.
public protocol ConnectionSampler: Sendable {
    func remoteEndpoints(processIdentifier: Int32) async throws -> [EgressEndpoint]
    /// Current IPv4 and IPv6 addresses of `host`.
    func addresses(of host: String) async -> Set<String>
}

public struct EgressReport: Sendable, Hashable, Codable {
    public struct Connection: Sendable, Hashable, Codable {
        public var endpoint: EgressEndpoint
        public var allowed: Bool
        /// Index of the first sample that saw it.
        public var firstSample: Int
    }

    public var phase: EgressPhase
    public var allowedHosts: [String]
    public var samples: Int
    public var connections: [Connection]
    public var passed: Bool { connections.allSatisfy(\.allowed) }
}

public struct EgressMonitor: Sendable {
    private let sampler: any ConnectionSampler
    private let sleeper: any HarnessSleeper

    public init(sampler: any ConnectionSampler, sleeper: any HarnessSleeper) {
        self.sampler = sampler
        self.sleeper = sleeper
    }

    /// `samples` samples `intervalNanoseconds` apart. A sample that fails (the process exited) ends the run early;
    /// what was seen until then is reported.
    public func run(
        processIdentifier: Int32, phase: EgressPhase, allowedHosts: [String], samples: Int, intervalNanoseconds: UInt64
    ) async -> EgressReport {
        var seen: [EgressEndpoint: EgressReport.Connection] = [:]
        var taken = 0
        for index in 0..<max(1, samples) {
            guard let endpoints = try? await sampler.remoteEndpoints(processIdentifier: processIdentifier) else { break }
            taken += 1
            let allowed = phase == .production ? await addresses(allowedHosts) : []
            for endpoint in endpoints where seen[endpoint] == nil {
                seen[endpoint] = .init(
                    endpoint: endpoint, allowed: endpoint.isLoopback || allowed.contains(endpoint.address),
                    firstSample: index)
            }
            if index + 1 < samples { try? await sleeper.sleep(nanoseconds: intervalNanoseconds) }
        }
        return EgressReport(
            phase: phase, allowedHosts: phase == .production ? allowedHosts : [], samples: taken,
            connections: seen.values.sorted { $0.endpoint < $1.endpoint })
    }

    private func addresses(_ hosts: [String]) async -> Set<String> {
        var all = Set<String>()
        for host in hosts { all.formUnion(await sampler.addresses(of: host)) }
        return all
    }
}
