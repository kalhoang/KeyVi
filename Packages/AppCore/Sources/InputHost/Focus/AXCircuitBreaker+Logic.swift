// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-pid AX circuit breaker (PLT-R384). A value owned by the ax thread.

import RealtimeSupport

extension AXCircuitBreaker {
    mutating func record(pid: Int32, at instant: MonotonicInstant) -> Bool {
        prune(at: instant)
        guard !isOpen(pid: pid, at: instant) else { return false }
        var timeouts = recentTimeouts[pid, default: []].filter {
            instant.nanoseconds(since: $0) < windowNanoseconds
        }
        timeouts.append(instant)
        guard timeouts.count >= threshold else {
            recentTimeouts[pid] = timeouts
            return false
        }
        recentTimeouts[pid] = nil
        openUntil[pid] = MonotonicInstant(nanoseconds: instant.nanoseconds &+ cooldownNanoseconds)
        return true
    }

    /// Forgets expired breakers and stale timeouts so the tables do not grow with every pid ever seen.
    private mutating func prune(at instant: MonotonicInstant) {
        openUntil = openUntil.filter { instant < $0.value }
        recentTimeouts = recentTimeouts.filter { entry in
            entry.value.contains { instant.nanoseconds(since: $0) < windowNanoseconds }
        }
    }

    static func nanoseconds(_ duration: TimeSpan) -> UInt64 { duration.unsignedNanoseconds }
}
