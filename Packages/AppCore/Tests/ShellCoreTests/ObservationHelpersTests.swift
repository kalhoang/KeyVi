// SPDX-License-Identifier: GPL-3.0-or-later
//
// ADR 0315: `ObservableObject` replaces `@Observable` (macOS 14). `afterChange` replaces `withObservationTracking`
// for AppKit controllers; `relayChanges(of:)` lets views that observe a model update when an object it owns changes.

import Combine
import Foundation
import Testing

@testable import ShellCore

@MainActor
@Suite struct ObservationHelpersTests {
    private final class Child: ObservableObject {
        @Published var value = 0
    }

    private final class Parent: ObservableObject {
        let child = Child()
        private var relay: AnyCancellable?
        init() { relay = relayChanges(of: child) }
    }

    @Test func aParentRepublishesItsChildsChanges() {
        let parent = Parent()
        var notifications = 0
        let observation = parent.objectWillChange.sink { _ in notifications += 1 }
        parent.child.value = 1
        parent.child.value = 2
        #expect(notifications == 2)
        observation.cancel()
    }

    @Test func theRelayDoesNotKeepTheParentAlive() {
        weak var released: Parent?
        let child: Child
        do {
            let parent = Parent()
            released = parent
            child = parent.child
        }
        #expect(released == nil)
        child.value = 3  // no parent left to notify; must not crash
    }

    @Test func afterChangeRunsOnceTheNewValueIsInPlace() async {
        let child = Child()
        let seen = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            var observation: AnyCancellable?
            observation = child.afterChange {
                done.resume(returning: child.value)
                observation?.cancel()
            }
            child.value = 7
        }
        #expect(seen == 7)
    }
}
