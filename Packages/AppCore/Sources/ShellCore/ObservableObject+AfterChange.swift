// SPDX-License-Identifier: GPL-3.0-or-later
//
// Observation helpers for `ObservableObject` models on macOS 12 (ADR 0315: `@Observable` and
// `withObservationTracking` need macOS 14).
//
// - `afterChange`: AppKit controllers that follow a model (the status item's label, window titles).
// - `relayChanges(of:)`: a model that owns another observable object (the interface language, the hotkey
//   recorder) re-publishes its changes, so views observing the model also update when the child changes, as
//   `@Observable` tracked nested reads.

public import Combine
internal import Dispatch

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// Calls `body` on the main actor after each change, once the new values are in place (`objectWillChange`
    /// fires before the change; delivery waits for the next turn of the main queue). Keep the returned
    /// cancellable for as long as the observation should last; changes in one turn may be delivered together.
    @MainActor
    public func afterChange(_ body: @escaping @MainActor () -> Void) -> AnyCancellable {
        objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { body() } }
    }

    /// Sends this object's `objectWillChange` whenever `child` is about to change. Keep the returned cancellable
    /// in the parent; the relay holds the parent weakly.
    public func relayChanges<Child: ObservableObject>(of child: Child) -> AnyCancellable {
        child.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
