// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R380: an observer's notifications are added all together or not at all, so a refusal while the app is still
// launching (kAXErrorCannotComplete, seen in the macOS 27 VM) is retried instead of leaving a partial observer.

import ApplicationServices
import Testing

@testable import InputHost

@Suite("AXObserverRegistration (PLT-R380)")
struct AXObserverRegistrationTests {
    private final class Calls {
        var added: [String] = []
        var removed: [String] = []
    }

    private func register(_ answers: [String: AXError], names: [String] = ["a", "b", "c"]) -> ([String]?, Calls) {
        let calls = Calls()
        let result = AXObserverRegistration.register(
            names,
            add: { name in
                calls.added.append(name)
                return answers[name] ?? .success
            },
            remove: { calls.removed.append($0) })
        return (result, calls)
    }

    @Test func everyNameIsAdded() {
        let (result, calls) = register([:])
        #expect(result == ["a", "b", "c"])
        #expect(calls.removed.isEmpty)
    }

    @Test func anAlreadyRegisteredNameCounts() {
        let (result, _) = register(["b": .notificationAlreadyRegistered])
        #expect(result == ["a", "b", "c"])
    }

    @Test func anAppThatCannotCompleteYetGetsNothingAndWhatWasAddedIsRemoved() {
        let (result, calls) = register(["b": .cannotComplete])
        #expect(result == nil)
        #expect(calls.added == ["a", "b"])  // stops at the refusal
        #expect(calls.removed == ["a"])
    }

    @Test func anUnsupportedNameIsSkipped() {
        let (result, calls) = register(["b": .notificationUnsupported])
        #expect(result == ["a", "c"])
        #expect(calls.removed.isEmpty)
    }

    @Test func nothingAddedIsNil() {
        let (result, _) = register(["a": .notificationUnsupported, "b": .failure, "c": .notificationUnsupported])
        #expect(result == nil)
    }
}
