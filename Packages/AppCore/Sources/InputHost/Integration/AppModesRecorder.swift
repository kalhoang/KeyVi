// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Delivery of the memory documents the ax thread emits to SettingsStore (PLT-R392, PRD-R20). One unstructured
// task per document has no ordering guarantee, and the store replaces the remembered modes wholesale, so an
// older document could overwrite a newer one on disk. The recorder hands them over one at a time, in emission
// order, which `AppModeMemory.merged` also relies on (EmittedModeHistory.acknowledge). Workstream W2-A.

internal import RealtimeSupport
internal import SettingsStore

/// Serial, in-order delivery of emitted documents to a sink (production: `SettingsStore.recordAppModes`).
final class AppModesRecorder: Sendable {
    typealias Sink = @Sendable (AppModesDocument) async -> Void

    /// Documents recorded and not yet delivered.
    private final class Pending: Sendable {
        let count = Atomic<Int>(0)
    }

    private let continuation: AsyncStream<AppModesDocument>.Continuation
    private let consumer: Task<Void, Never>
    private let pending = Pending()

    init(sink: @escaping Sink) {
        let (stream, continuation) = AsyncStream.makeStream(of: AppModesDocument.self)
        let pending = self.pending
        self.continuation = continuation
        consumer = Task {
            for await document in stream {
                await sink(document)
                pending.count.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            }
        }
    }

    convenience init(store: SettingsStore) {
        self.init { document in await store.recordAppModes(document) }
    }

    /// Any thread (the ax thread's memory observer). Never blocks.
    func record(_ document: AppModesDocument) {
        pending.count.wrappingAdd(1, ordering: .sequentiallyConsistent)
        continuation.yield(document)
    }

    /// Documents recorded and not yet delivered (tests wait for zero before reading the store).
    var pendingCount: Int { pending.count.load(ordering: .sequentiallyConsistent) }

    /// Delivers what is queued, then ends.
    func finish() { continuation.finish() }

    /// Tests: waits until everything recorded before `finish()` was delivered.
    func finished() async { await consumer.value }
}
