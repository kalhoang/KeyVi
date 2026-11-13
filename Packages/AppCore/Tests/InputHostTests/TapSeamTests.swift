// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Skeleton seam tests (ADR 0313): keep green; W1-F2 owns and may extend.
import CoreGraphics
import RealtimeSupport
import Testing
@testable import InputHost

@Suite struct TapEventMaskTests {
    /// PRD-R14 (MUST) cancels the toggle tap on scroll, so the standard mask includes scrollWheel (PLT-R301).
    @Test func standardMaskIncludesScrollWheel() {
        let mask = TapEventMask.standard.cgMask
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            #expect(mask & (CGEventMask(1) << CGEventMask(type.rawValue)) != 0)
        }
        #expect(mask & (CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue)) == 0)
        #expect(TapEventMask(includeScrollWheel: false).cgMask & (CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)) == 0)
    }
}

@Suite struct CallbackWatchdogTests {
    @Test func tracksRunningCallback() {
        let watchdog = CallbackWatchdog(activitySignal: nil)
        let start = MonotonicInstant(nanoseconds: 5_000_000_000)
        #expect(watchdog.runningCallbackDuration(now: start) == nil)
        watchdog.enter(at: start)
        #expect(watchdog.isInsideCallback)
        #expect(watchdog.runningCallbackDuration(now: start.advanced(byMicroseconds: 300_000)) == 300_000_000)
        watchdog.exit()
        #expect(!watchdog.isInsideCallback)
        #expect(watchdog.lastCallbackEntry == start)
    }
}
