// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R397A (2026-11-15): a keyUp of a non-modifier key whose keyDown the tap never saw proves the app received
// input the engine did not see (Secure Event Input bursts shorter than the PLT-R395 poll, Pa's trace of 14/11/2026:
// "hay sao" became "hayayao" when an edit deleted by count the Space and "s" the tap never saw). The tap takes a hard
// boundary, so no later edit deletes by a stale count.

import AppModel
import Diagnostics
import Injection
import TestSupport
import Testing

@testable import InputHost

@Suite struct KeyPipelineUnseenInputTests {
    private func taplogCodes(_ fixture: PipelineFixture) -> [TapLogRecord] {
        var records: [TapLogRecord] = []
        fixture.tapLog.drain { records.append($0) }
        return records
    }

    /// The trace's shape: "da" composed, the app got a key the tap never saw (only its keyUp arrives), then "a" must
    /// not become "dâ" by deleting what the app received in between.
    @Test func anOrphanKeyUpEndsTheCompositionPLTR397A() {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.d, Key.a])
        #expect(fixture.keyUp(Key.s) == .pass)  // its keyDown went to the app, not to the tap
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.log.resets == [.unknown])
        #expect(fixture.keyDown(Key.a) == .pass)  // a fresh word: no edit
        #expect(fixture.popJobs().isEmpty)
        let unseen = taplogCodes(fixture).filter { $0.code == .unseenKeyUp }
        #expect(unseen.map(\.a) == [UInt64(Key.s)])  // the key code only (PLT-R901)
    }

    /// While a job is in flight the boundary is also marked in FIFO order.
    @Test func theBoundaryIsQueuedWhileAJobIsInFlightPLTR397A() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight
        fixture.keyUp(Key.s)
        #expect(fixture.popJobs().compactMap(\.boundaryReason) == [.unseenInput])
    }

    /// Normal typing, rollover and autorepeat never look unseen.
    @Test func seenKeysAreNotABoundaryPLTR397A() {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.d)
        fixture.keyDown(Key.a)
        fixture.keyDown(Key.a, autorepeat: true)
        fixture.keyUp(Key.d)
        fixture.keyUp(Key.a)
        fixture.keyDown(Key.u)
        fixture.keyUp(Key.u)
        #expect(fixture.log.resets == [.unknown])  // the autorepeat only (PLT-R351)
        #expect(taplogCodes(fixture).allSatisfy { $0.code != .unseenKeyUp })
    }

    /// A second keyUp of the same press is unseen too; a keyUp of a modifier key code is never judged.
    @Test func onlyNonModifierKeysCountPLTR397A() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.send(PipelineFixtures.keyEvent(.keyUp, Key.shift))
        fixture.send(PipelineFixtures.keyEvent(.keyUp, 0x3F))  // fn
        #expect(fixture.log.resets.isEmpty)
        fixture.press(Key.a)
        fixture.keyUp(Key.a)
        #expect(fixture.log.resets == [.unknown])
    }

    /// The pairing of consumed keys is untouched: the keyUp of a key consumed for an edit is seen.
    @Test func aConsumedKeyIsSeenPLTR397A() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // consumed for "â"
        fixture.completeJobs()
        #expect(fixture.keyUp(Key.a) == .swallow)
        #expect(fixture.log.resets.isEmpty)
    }
}

/// PLT-R397A property: whatever keys the tap misses, once their keyUp arrived no edit changes text the field held at
/// that moment (it deletes only what was typed since that boundary). Random letters, separators and Backspaces, with
/// keys that reach the field without reaching the tap (secure-input bursts), then their keyUp through the tap.
@Suite("UnseenInputPropertyTests") struct UnseenInputPropertyTests {
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private static let characters: [UInt16: Character] = [
        Key.a: "a", Key.s: "s", Key.w: "w", Key.u: "u", Key.d: "d", Key.e: "e", Key.space: " ",
    ]
    private static let pool: [UInt16] = [Key.a, Key.a, Key.s, Key.w, Key.u, Key.d, Key.e, Key.space, Key.backspace]

    /// What the app shows, plus the text the last unseen-key boundary vouches for.
    private struct Field {
        var text: [Character] = []
        var protected: [Character] = []
        var violation: String?

        mutating func type(_ code: UInt16) {
            if code == Key.backspace {
                if !text.isEmpty { text.removeLast() }
                if text.count < protected.count { protected = text }  // the user deleted it: no longer vouched for
            } else if let character = UnseenInputPropertyTests.characters[code] {
                text.append(character)
            }
        }

        mutating func edit(_ job: EditJob) {
            text.removeLast(min(job.deleteCount, text.count))
            text.append(contentsOf: job.insertion)
            if violation == nil, !text.starts(with: protected) {
                violation = "an edit deleting \(job.deleteCount) changed text from before the unseen key"
            }
        }
    }

    /// `code` is the key whose keyDown was just processed (nil for a keyUp, which types nothing).
    private func deliver(_ verdict: TapVerdict, _ code: UInt16?, _ fixture: PipelineFixture, _ field: inout Field) {
        if verdict == .pass, fixture.lastOutcome == .passed, let code { field.type(code) }
        for job in fixture.completeJobs() {
            switch job {
            case .edit(let edit): field.edit(edit)
            case .replay(_, let record) where record.kind == .keyDown: field.type(record.keyCode.rawValue)
            default: break
            }
        }
    }

    private func run(seed: UInt64, length: Int) -> String? {
        var random = Random(state: seed)
        let fixture = PipelineFixture(log: EngineEventLog(keepsEntries: false))
        var field = Field()
        var pendingUnseen: [UInt16] = []
        for _ in 0..<length {
            if random.below(10) == 0, let code = Self.characters.keys.sorted()[safe: random.below(7)] {
                field.type(code)  // reached the app, not the tap
                pendingUnseen.append(code)
            } else {
                let code = Self.pool[random.below(Self.pool.count)]
                deliver(fixture.keyDown(code), code, fixture, &field)
                deliver(fixture.keyUp(code), nil, fixture, &field)
            }
            if !pendingUnseen.isEmpty, random.below(3) == 0 {
                for code in pendingUnseen { deliver(fixture.keyUp(code), nil, fixture, &field) }
                pendingUnseen.removeAll()
                field.protected = field.text  // the boundary vouches for nothing before it
            }
            if let violation = field.violation { return "seed \(seed): \(violation)" }
        }
        return nil
    }

    @Test func orphanKeyUpsNeverLetAnEditReachBackPastThemProperty() {
        let failures = (0..<2_000).compactMap { run(seed: 0xC0FFEE &+ UInt64($0), length: 48) }
        #expect(failures.isEmpty, "\(failures.count) failing sequences, first: \(failures.prefix(3))")
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
