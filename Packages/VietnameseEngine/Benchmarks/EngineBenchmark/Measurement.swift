// SPDX-License-Identifier: MPL-2.0

import Foundation
import VietnameseEngine

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Latency percentiles of one set of per-event samples, in nanoseconds.
struct Percentiles: Codable, Equatable {
    var events: Int
    var p50: Int64
    var p99: Int64
    var p999: Int64
    var max: Int64

    init(_ unsorted: [Int64]) {
        let samples = unsorted.sorted()
        func at(_ fraction: Double) -> Int64 {
            guard !samples.isEmpty else { return 0 }
            return samples[Swift.min(samples.count - 1, Int(Double(samples.count) * fraction))]
        }
        events = samples.count
        p50 = at(0.5)
        p99 = at(0.99)
        p999 = at(0.999)
        max = samples.last ?? 0
    }

    init(events: Int, p50: Int64, p99: Int64, p999: Int64, max: Int64) {
        self.events = events
        self.p50 = p50
        self.p99 = p99
        self.p999 = p999
        self.max = max
    }

    /// QA-R14: the median of each percentile over several runs.
    static func median(_ runs: [Percentiles]) -> Percentiles {
        func median(_ values: [Int64]) -> Int64 {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return Percentiles(
            events: runs.first?.events ?? 0, p50: median(runs.map(\.p50)), p99: median(runs.map(\.p99)),
            p999: median(runs.map(\.p999)), max: median(runs.map(\.max)))
    }
}

enum Timing {
    static let clock = ContinuousClock()

    static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    /// The median cost of reading the clock twice, which every per-event sample includes.
    static func clockOverhead() -> Int64 {
        var samples: [Int64] = []
        samples.reserveCapacity(100_000)
        for _ in 0..<100_000 {
            let start = clock.now
            samples.append(nanoseconds(start.duration(to: clock.now)))
        }
        return Percentiles(samples).p50
    }

    /// Replays `workload` in a fresh session and returns one sample per event.
    static func perEvent(_ workload: Workload, sink: inout Int) -> [Int64] {
        var samples: [Int64] = []
        samples.reserveCapacity(workload.events.count)
        var session = Session(engine: workload.engine)
        for event in workload.events {
            let start = clock.now
            let output = session.handle(event)
            let end = clock.now
            sink &+= output.composingText.utf8.count
            samples.append(nanoseconds(start.duration(to: end)))
        }
        return samples
    }

    /// The fixed reference loop of ENG-R1233: integer arithmetic and scattered memory writes that do not
    /// depend on the engine, timed so that results from different machines can be compared.
    static func referenceLoop(sink: inout Int) -> Int64 {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        var buffer = [UInt16](repeating: 0, count: 4_096)
        let start = clock.now
        for index in 0..<20_000_000 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            buffer[Int(value & 4_095)] &+= UInt16(truncatingIfNeeded: index)
        }
        let elapsed = nanoseconds(start.duration(to: clock.now))
        sink &+= Int(buffer.reduce(0, &+))
        return elapsed
    }
}

enum SystemInfo {
    /// Physical memory footprint (Darwin) or resident set size (Linux) of this process, in bytes.
    static func residentBytes() -> Int {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        #else
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
        let fields = statm.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else { return 0 }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    static func cpuName() -> String {
        #if canImport(Darwin)
        return sysctlString("machdep.cpu.brand_string") ?? "unknown"
        #else
        let cpuinfo = (try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)) ?? ""
        let line = cpuinfo.split(separator: "\n").first { $0.hasPrefix("model name") }
        return line.map { String($0.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces) }
            ?? "unknown"
        #endif
    }

    static func model() -> String {
        #if canImport(Darwin)
        return sysctlString("hw.model") ?? "unknown"
        #else
        return "linux"
        #endif
    }

    #if canImport(Darwin)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #endif
}
