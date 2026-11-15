// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R332, PLT-R730 (amended 15/11/2026): `TapThread.start()` runs on the main thread when the host creates its
// tap (also when a grant comes back), so it must not wait without bound for a creation that hangs in the system.
// After the creation timeout it reports failure (the lifecycle retries on its backoff) and a tap that arrives later
// is invalidated, never enabled.
import Dispatch
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

@Suite struct TapCreationTimeoutTests {
    @Test func aCreationThatHangsFailsAfterTheTimeoutAndTheLateTapNeverGoesLive() async throws {
        let factory = FakeEventTapFactory()
        factory.holdCreation()
        // Releases the hung creation even if `start()` waits for it, so a regression fails instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { factory.releaseCreation() }
        let thread = TapThread(factory: factory, creationTimeout: .milliseconds(200)) {
            TrivialHandler(probe: HandlerProbe())
        }
        let started = Date()
        let created = thread.start()
        let waited = Date().timeIntervalSince(started)
        #expect(!created, "a hung creation is a failed creation")
        #expect(waited < 1.0, "start() waited \(waited) s")
        factory.releaseCreation()
        #expect(thread.waitUntilExited(timeout: .seconds(3)), "the thread leaves once the late creation returns")
        #expect(!thread.isRunning)
        #expect(factory.handles.count == 1)
        #expect(factory.handles.allSatisfy { $0.isInvalidated && !$0.isEnabled }, "the late tap is dropped")
    }

    @Test func aPromptCreationIsUnaffected() {
        let factory = FakeEventTapFactory()
        let thread = TapThread(factory: factory, creationTimeout: .milliseconds(200)) {
            TrivialHandler(probe: HandlerProbe())
        }
        #expect(thread.start())
        defer { thread.stop() }
        #expect(thread.isRunning && thread.isEnabled)
    }
}
