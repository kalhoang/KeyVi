// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared builders for the host-service tests (W1-E).

import AppModel
import Foundation
import RealtimeSupport
import TestSupport

@testable import InputHost

func ms(_ value: UInt64) -> MonotonicInstant { MonotonicInstant(nanoseconds: value * 1_000_000) }

func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

func sourceID(_ raw: String) -> InputSourceID { InputSourceID(rawValue: raw)! }

/// Collects values published from any thread.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
    var last: Value? { storage.withLock { $0.last } }
    var count: Int { storage.withLock { $0.count } }
}

extension InputSourceInfo {
    static func layout(_ id: String, name: String = "Layout", languages: [String] = ["en"]) -> InputSourceInfo {
        InputSourceInfo(
            id: sourceID(id), kind: .asciiLayout, localizedName: name, languages: languages, isBuiltInVietnamese: false)
    }
}

/// Forwards to a `ManualScheduler` and records every requested timer, so tests can check the PLT-R803 leeway.
final class TimerRequestRecorder: TimerScheduler, Sendable {
    struct Request: Equatable {
        var delay: TimeSpan
        var leeway: TimeSpan
        var repeating: Bool
    }

    let base: ManualScheduler
    private let storage = Mutex<[Request]>([])
    var requests: [Request] { storage.withLock { $0 } }

    init(base: ManualScheduler) { self.base = base }

    func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        storage.withLock { $0.append(Request(delay: delay, leeway: leeway, repeating: false)) }
        return base.schedule(after: delay, leeway: leeway, handler)
    }

    func scheduleRepeating(every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        storage.withLock { $0.append(Request(delay: interval, leeway: leeway, repeating: true)) }
        return base.scheduleRepeating(every: interval, leeway: leeway, handler)
    }
}

/// A reference filled in after construction, for callbacks that call back into the object that runs them.
final class LateBinding<Value: AnyObject & Sendable>: Sendable {
    private let storage = Mutex<Value?>(nil)
    var value: Value? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Tracks how deeply a callback is nested inside itself.
final class NestingProbe: Sendable {
    private let state = Mutex((depth: 0, deepest: 0))
    var deepest: Int { state.withLock { $0.deepest } }
    func run(_ body: () -> Void) {
        state.withLock { state in
            state.depth += 1
            state.deepest = max(state.deepest, state.depth)
        }
        body()
        state.withLock { $0.depth -= 1 }
    }
}
