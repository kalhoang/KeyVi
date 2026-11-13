// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Counts heap allocations and frees on one thread through libmalloc's `malloc_logger` hook (the hook
// MallocStackLogging uses; every malloc-family call reports to it while it is set). Proves PLT-R305 "no
// steady-state heap allocation" for the tap path: spans inside the engine call are excluded with
// `pause()`/`resume()`. Sanitizer runtimes replace malloc and never call the hook; `isAvailable` tells.

internal import Darwin
public import InputHost
internal import Synchronization
public import VietnameseEngine

public enum AllocationCounter {
    public struct Counts: Sendable, Hashable {
        public var allocations: Int
        public var deallocations: Int
    }

    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// One measurement at a time across the whole test process.
    private static let gate = Mutex(())

    /// Runs `body` with the hook installed and returns what the calling thread allocated and freed outside
    /// paused spans.
    public static func measure(_ body: () -> Void) -> Counts {
        gate.withLock { _ in
            guard let slot = hookSlot else { return Counts(allocations: -1, deallocations: -1) }
            allocationCount.store(0, ordering: .sequentiallyConsistent)
            deallocationCount.store(0, ordering: .sequentiallyConsistent)
            pauseDepth.store(0, ordering: .sequentiallyConsistent)
            countedThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
            slot.pointee = hook
            body()
            slot.pointee = nil
            countedThread.store(0, ordering: .sequentiallyConsistent)
            return Counts(
                allocations: allocationCount.load(ordering: .sequentiallyConsistent),
                deallocations: deallocationCount.load(ordering: .sequentiallyConsistent))
        }
    }

    /// The hook exists and sees an allocation on this thread (false under ASan/TSan, which replace malloc).
    public static var isAvailable: Bool {
        measure {
            let pointer = malloc(64)
            free(pointer)
        }.allocations > 0
    }

    public static func pause() { pauseDepth.wrappingAdd(1, ordering: .sequentiallyConsistent) }
    public static func resume() { pauseDepth.wrappingSubtract(1, ordering: .sequentiallyConsistent) }

    private static let hook: Logger = { type, _, _, _, _, _ in
        guard UInt(bitPattern: pthread_self()) == countedThread.load(ordering: .relaxed),
            pauseDepth.load(ordering: .relaxed) == 0
        else { return }
        // `stack_logging_type_alloc` (2) and `stack_logging_type_dealloc` (4); realloc reports both.
        if type & 2 != 0 { allocationCount.wrappingAdd(1, ordering: .relaxed) }
        if type & 4 != 0 { deallocationCount.wrappingAdd(1, ordering: .relaxed) }
    }

    /// Address of `malloc_logger` exported by libsystem_malloc (RTLD_DEFAULT lookup), written only under `gate`.
    private static let hookAddress: UInt? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger").map {
        UInt(bitPattern: $0)
    }

    private static var hookSlot: UnsafeMutablePointer<Logger?>? {
        hookAddress.flatMap { UnsafeMutablePointer<Logger?>(bitPattern: $0) }
    }
}

private let countedThread = Atomic<UInt>(0)
private let pauseDepth = Atomic<Int>(0)
private let allocationCount = Atomic<Int>(0)
private let deallocationCount = Atomic<Int>(0)

/// Wraps a factory so every engine call runs with allocation counting paused: the PLT-R305 test measures the
/// pipeline, not the engine (whose own budget is ENG-R1230).
public struct AllocationExcludingFactory<Base: CompositionEngineFactory>: CompositionEngineFactory {
    public typealias Hotkeys = Base.Hotkeys

    public struct Engine: CompositionEngine {
        var base: Base.Engine
        public mutating func handle(_ event: EngineEvent) -> EngineOutput {
            AllocationCounter.pause()
            defer { AllocationCounter.resume() }
            return base.handle(event)
        }
        public var activeDisplay: String { base.activeDisplay }
    }

    private let base: Base
    public init(_ base: Base) { self.base = base }

    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> Engine {
        AllocationCounter.pause()
        defer { AllocationCounter.resume() }
        return Engine(base: base.makeEngine(for: variant, settings: settings))
    }
}
