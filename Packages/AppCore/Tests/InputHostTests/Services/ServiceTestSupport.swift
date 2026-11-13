// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared builders for the host-service tests (W1-E).

import AppModel
import Foundation
import RealtimeSupport
import Synchronization

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
