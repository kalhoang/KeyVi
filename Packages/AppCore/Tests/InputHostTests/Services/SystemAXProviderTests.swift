// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pure parts of the production AX wrapper (PLT-R380, PLT-R384). No AX message is sent: calling AX needs the
// Accessibility permission, which tests never request (the real path runs on the self-hosted runner).

import ApplicationServices
import Injection
import Synchronization
import Testing

@testable import InputHost

@Suite("SystemAXProvider pure parts (PLT-R380, PLT-R384)")
struct SystemAXProviderTests {
    @Test func notificationNamesRoundTrip() {
        for kind in AXNotificationKind.allCases {
            #expect(AXNotificationNames.kind(for: AXNotificationNames.name(for: kind)) == kind)
        }
        #expect(AXNotificationNames.name(for: .focusedElementChanged) == kAXFocusedUIElementChangedNotification)
        #expect(AXNotificationNames.kind(for: "AXSomethingElse") == nil)
    }

    @Test func handlerBoxDeliversOnlyKnownNotifications() {
        let received = Mutex<[AXNotificationKind]>([])
        let box = AXObserverHandlerBox { kind in received.withLock { $0.append(kind) } }
        box.deliver(kAXTitleChangedNotification)
        box.deliver("AXUnknown")
        #expect(received.withLock { $0 } == [.titleChanged])
    }

    @Test func messagingTimeoutIs100Milliseconds() {
        #expect(SystemAXProvider.messagingTimeout == 0.1)
        #expect(SystemAXProvider.maximumAncestors == 6)
    }

    @Test func errorMapping() {
        let timedOut: AXCallResult<Int32> = AXRead.failure(.cannotComplete)
        guard case .timedOut = timedOut else {
            Issue.record("cannotComplete must be a timeout")
            return
        }
        let failed: AXCallResult<Int32> = AXRead.failure(.illegalArgument)
        guard case .failed(let code) = failed else {
            Issue.record("expected failure")
            return
        }
        #expect(code == AXError.illegalArgument.rawValue)
        let outcome = AXRead.Outcome<String>.success("AXButton")
        #expect(outcome.value == .some("AXButton"))
        #expect(AXRead.Outcome<String>.timedOut.value == nil)
        guard case .unavailable = AXRead.Outcome<String>.unavailable.flatMap({ _ in AXCallResult<Int>.success(1) })
        else {
            Issue.record("expected unavailable")
            return
        }
    }
}
