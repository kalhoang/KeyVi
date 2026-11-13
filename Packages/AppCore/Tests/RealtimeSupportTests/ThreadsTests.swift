// SPDX-License-Identifier: LicenseRef-App-Pending

import Foundation
import Testing

@testable import RealtimeSupport

@Suite struct ThreadConfinedTests {
    @Test func mutatesInPlaceOnTheOwningThread() {
        let confined = ThreadConfined([1, 2])
        confined.withValue { $0.append(3) }
        #expect(confined.withValue { $0 } == [1, 2, 3])
    }

    @Test func secondThreadTrapsInDebugBuilds() async {
        await #expect(processExitsWith: .failure) {
            touchFromTwoThreads()
        }
    }
}

/// Binds a `ThreadConfined` to the calling thread, then touches it from another one. Returning normally
/// (no trap) makes the exit test fail.
private func touchFromTwoThreads() {
    let confined = ThreadConfined(0)
    confined.withValue { $0 += 1 }
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        confined.withValue { $0 += 1 }
        finished.signal()
    }
    thread.start()
    _ = finished.wait(timeout: .now() + 5)
}

/// CFRunLoopSource is thread-safe but not annotated `Sendable`.
private struct SendableSource: @unchecked Sendable {
    let source: CFRunLoopSource
}

@Suite struct RunLoopThreadTests {
    @Test func performRunsOnTheDedicatedThread() async {
        let thread = RunLoopThread(name: "test.ax", qualityOfService: .userInitiated)
        #expect(!thread.isCurrentThread)
        thread.start()
        thread.start()  // idempotent: no second thread
        let ranOnThread = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            thread.perform { done.resume(returning: thread.isCurrentThread && Thread.current.name == "test.ax") }
        }
        #expect(ranOnThread)
        #expect(thread.name == "test.ax")
        #expect(thread.qualityOfService == .userInitiated)
        thread.stop()
    }

    @Test func sourcesCanBeAddedAndRemoved() async {
        let thread = RunLoopThread(name: "test.sources", qualityOfService: .utility)
        thread.start()
        var context = CFRunLoopSourceContext()
        let wrapped = SendableSource(source: CFRunLoopSourceCreate(nil, 0, &context)!)
        thread.addSource(wrapped.source)
        let contained = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            thread.perform {
                done.resume(returning: CFRunLoopContainsSource(CFRunLoopGetCurrent(), wrapped.source, .defaultMode))
            }
        }
        #expect(contained)
        thread.removeSource(wrapped.source)
        let removed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            thread.perform {
                done.resume(returning: !CFRunLoopContainsSource(CFRunLoopGetCurrent(), wrapped.source, .defaultMode))
            }
        }
        #expect(removed)
        thread.stop()
    }

    @Test func callsBeforeStartAreNoOps() {
        let thread = RunLoopThread(name: "test.idle", qualityOfService: .background)
        var context = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(nil, 0, &context)!
        thread.perform { Issue.record("must not run before start") }
        thread.addSource(source)
        thread.removeSource(source)
        thread.stop()
        #expect(!thread.isCurrentThread)
    }
}

@Suite struct InlineUTF16BufferTests {
    @Test func buildsFromABufferWithoutAllocating() {
        let units: [UInt16] = [0x0065, 0x0302, 0x0301]
        let inline = units.withUnsafeBufferPointer { InlineUTF16($0) }
        #expect(inline?.count == 3)
        #expect(inline?.withUnits { Array($0) } == units)
        let tooLong = [UInt16](repeating: 0x61, count: 21).withUnsafeBufferPointer { InlineUTF16($0) }
        #expect(tooLong == nil)
    }

    @Test func equalValuesHashEqually() {
        let first = InlineUTF16("đá")
        let second = InlineUTF16("đá")
        #expect(first == second)
        #expect(first?.hashValue == second?.hashValue)
        #expect(InlineUTF16("a") != InlineUTF16("b"))
        #expect(InlineUTF16.empty.count == 0)
        #expect(InlineUTF16.empty.string.isEmpty)
        #expect(Set([first, second]).count == 1)
    }
}
