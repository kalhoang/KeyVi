// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared helpers for the W1-A stress tests.

import Darwin

enum StressScale {
    /// True when Thread Sanitizer instruments this process. TSan slows atomics by one to two orders of
    /// magnitude, so stress loops run a tenth of the iterations there; plain runs keep the full count.
    static let isThreadSanitized: Bool = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
    }()

    /// The acceptance count (10 million) in plain runs, one million under Thread Sanitizer.
    static let concurrentIterations = isThreadSanitized ? 1_000_000 : 10_000_000
}
