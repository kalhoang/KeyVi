// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Duration arithmetic shared by the tap watchdog and the lifecycle state machine (W1-F2). Not on the tap thread.

extension Duration {
    /// Whole nanoseconds of a non-negative duration (saturating at zero and at `UInt64.max`).
    var nanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0, attoseconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .max }
        let (total, carry) = whole.addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
        return carry ? .max : total
    }
}
