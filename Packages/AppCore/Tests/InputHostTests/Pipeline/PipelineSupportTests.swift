// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The property suite is only as good as its checker: these tests show that the ledger, the window-server
// model, the generator, the scripted engine and the reference recogniser behave as the suites assume, and
// that the ledger reports every kind of violation it claims to detect.

import AppModel
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct ScriptedEngineTests {
    private func edit(_ output: EngineOutput) -> (TextEdit, Bool)? {
        if case .edit(let edit, let pass) = output.action { return (edit, pass) }
        return nil
    }

    @Test func composesWithTheScriptedRules() throws {
        var engine = ScriptedEngine()
        #expect(engine.handle(.key(KeyInput("a"))).action == .passThrough)
        let doubled = try #require(edit(engine.handle(.key(KeyInput("a")))))
        #expect(doubled.0 == TextEdit(deleteCount: 1, deleteUTF16Count: 1, insert: "â") && !doubled.1)
        let accented = try #require(edit(engine.handle(.key(KeyInput("s")))))
        #expect(accented.0.insert == "ấ")
        #expect(engine.activeDisplay == "ấ")
        let horn = try #require(edit(engine.handle(.key(KeyInput("w")))))
        #expect(horn.0 == TextEdit(deleteCount: 0, deleteUTF16Count: 0, insert: "ư"))
        _ = engine.handle(.reset(.focusChanged))
        _ = engine.handle(.key(KeyInput("u")))
        let hook = try #require(edit(engine.handle(.key(KeyInput("w")))))
        #expect(hook.0.deleteCount == 1 && hook.0.insert == "ư")
    }

    @Test func englishTokensRestoreAtTheBoundaryWithPassThrough() throws {
        var engine = ScriptedEngine()
        for character: Character in ["a", "x", "s"] { _ = engine.handle(.key(KeyInput(character))) }
        let restore = try #require(edit(engine.handle(.key(KeyInput(",")))))
        #expect(restore.0.insert == "axs" && restore.0.deleteCount == 2 && restore.1)
        #expect(engine.activeDisplay.isEmpty)
        _ = engine.handle(.key(KeyInput("b")))
        #expect(engine.handle(.key(KeyInput(" "))).action == .passThrough)
    }

    @Test func backspaceRemovesAnAccentOrPasses() throws {
        var engine = ScriptedEngine()
        #expect(engine.handle(.backspace).action == .passThrough)
        _ = engine.handle(.key(KeyInput("e")))
        _ = engine.handle(.key(KeyInput("s")))
        let undo = try #require(edit(engine.handle(.backspace)))
        #expect(undo.0.insert == "e")
        #expect(engine.handle(.backspace).action == .passThrough)
        #expect(engine.activeDisplay.isEmpty)
    }

    @Test func restoreToggleOnceThenPass() throws {
        var engine = ScriptedEngine()
        #expect(engine.handle(.restoreToggle).action == .passThrough)
        _ = engine.handle(.key(KeyInput("a")))
        _ = engine.handle(.key(KeyInput("a")))
        let restored = try #require(edit(engine.handle(.restoreToggle)))
        #expect(restored.0.insert == "aa")
        #expect(engine.handle(.restoreToggle).action == .passThrough)
    }

    @Test func factoryLogsCreationsAndEvents() {
        let log = EngineEventLog()
        let factory = ScriptedEngineFactory(log: log)
        var engine = factory.makeEngine(for: .default, settings: PipelineFixtures.settings())
        _ = engine.handle(.key(KeyInput("a")))
        _ = engine.handle(.reset(.unknown))
        #expect(log.entries == [.made(.default), .event(.key(KeyInput("a"))), .event(.reset(.unknown))])
        _ = ScriptedEngineFactory().makeEngine(for: .default, settings: PipelineFixtures.settings())
        log.clear()
        #expect(log.entries.isEmpty)
    }

    /// The PLT-R210 check: a feed after a transition needs a reset unless the engine was clean.
    @Test func eventLogDetectsAFeedWithoutAReset() {
        let log = EngineEventLog(keepsEntries: false)
        var engine = ScriptedEngineFactory(log: log).makeEngine(for: .default, settings: PipelineFixtures.settings())
        log.mark()
        _ = engine.handle(.key(KeyInput("a")))  // clean engine: fine
        log.mark()
        _ = engine.handle(.reset(.focusChanged))
        _ = engine.handle(.key(KeyInput("a")))  // reset first: fine
        log.mark()
        _ = engine.handle(.key(KeyInput("b")))  // dirty and no reset: violation
        #expect(log.resetViolations == 1)
        #expect(log.entries.isEmpty)
    }
}

@Suite struct ReferenceHotkeyRecognizerTests {
    private let start = MonotonicInstant(nanoseconds: 1_000_000_000)

    private func tap(_ recognizer: inout ReferenceHotkeyRecognizer, holdMicroseconds: UInt64) -> HotkeyResult {
        _ = recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.control), modifiers: [.control], at: start))
        _ = recognizer.handle(
            .flagsChanged(keyCode: KeyCode(rawValue: Key.shift), modifiers: [.control, .shift], at: start))
        _ = recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.shift), modifiers: [.control], at: start))
        let end = start.advanced(byMicroseconds: holdMicroseconds)
        return recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.control), modifiers: [], at: end))
    }

    /// PRD-R14: release within 500 ms toggles; a longer hold cancels.
    @Test func holdLongerThan500msCancels() {
        var recognizer = ReferenceHotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        #expect(tap(&recognizer, holdMicroseconds: 400_000) == .toggleTap)
        #expect(tap(&recognizer, holdMicroseconds: 600_000) == .none)
    }

    @Test func anotherKeyOrAnExtraModifierCancels() {
        var recognizer = ReferenceHotkeyRecognizer(toggle: .defaultToggle, restore: nil)
        _ = recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.control), modifiers: [.control], at: start))
        _ = recognizer.handle(
            .keyDown(keyCode: KeyCode(rawValue: Key.a), modifiers: [.control], autorepeat: false, at: start))
        #expect(
            recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.control), modifiers: [], at: start)) == .none
        )
        _ = recognizer.handle(
            .flagsChanged(keyCode: KeyCode(rawValue: Key.control), modifiers: [.control, .command], at: start))
        #expect(
            recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.control), modifiers: [], at: start)) == .none
        )
        #expect(recognizer.handle(.keyUp(keyCode: KeyCode(rawValue: Key.a), at: start)) == .none)
    }

    @Test func combosAndRestoreBindings() {
        let combo = HotkeyBinding.keyCombo(modifiers: [.command, .shift], keyCode: KeyCode(rawValue: Key.space))
        let restore = HotkeyBinding.keyCombo(modifiers: [.option], keyCode: KeyCode(rawValue: Key.a))
        var recognizer = ReferenceHotkeyRecognizer(toggle: combo, restore: restore)
        let space = KeyCode(rawValue: Key.space)
        #expect(
            recognizer.handle(
                .keyDown(keyCode: space, modifiers: [.command, .shift, .rightCommand], autorepeat: false, at: start))
                == .toggleCombo)
        #expect(
            recognizer.handle(.keyDown(keyCode: space, modifiers: [.command, .shift], autorepeat: true, at: start))
                == .none)
        #expect(
            recognizer.handle(.keyDown(keyCode: space, modifiers: [.command], autorepeat: false, at: start)) == .none)
        #expect(
            recognizer.handle(
                .keyDown(keyCode: KeyCode(rawValue: Key.a), modifiers: [.option], autorepeat: false, at: start))
                == .restoreCandidate)
        #expect(
            recognizer.handle(.flagsChanged(keyCode: KeyCode(rawValue: Key.shift), modifiers: [.shift], at: start))
                == .none)
        var escape = ReferenceHotkeyRecognizer(toggle: .defaultToggle, restore: .key(KeyCode(rawValue: Key.escape)))
        #expect(
            escape.handle(
                .keyDown(keyCode: KeyCode(rawValue: Key.escape), modifiers: [.shift], autorepeat: false, at: start))
                == .none)
        #expect(
            escape.handle(.keyDown(keyCode: KeyCode(rawValue: Key.escape), modifiers: [], autorepeat: false, at: start))
                == .restoreCandidate)
    }
}

@Suite struct SimulatedWindowServerTests {
    @Test func fifoInBothModes() {
        let server = SimulatedWindowServer(mode: .lagging)
        for index in 0..<5 { server.enqueue(.physical(index: index, PipelineFixtures.keyEvent(.keyDown, Key.a))) }
        #expect(server.count == 5)
        let first = server.drain(maxEvents: 2).compactMap { pending -> Int? in
            if case .physical(let index, _) = pending { return index }
            return nil
        }
        #expect(first == [0, 1])
        #expect(server.drain(maxEvents: 0).isEmpty)
        #expect(server.drain(maxEvents: Int.max).count == 3)
        #expect(server.count == 0)
        #expect(SimulatedWindowServer(mode: .immediate).mode == .immediate)
    }
}

@Suite struct RandomEventGeneratorTests {
    @Test func sameSeedSameSequence() {
        var first = RandomEventGenerator(seed: 42)
        var second = RandomEventGenerator(seed: 42)
        #expect(first.sequence(length: 200) == second.sequence(length: 200))
        var other = RandomEventGenerator(seed: 43)
        #expect(other.sequence(length: 200) != RandomEventGenerator(seed: 42).sequenceCopy(length: 200))
    }

    @Test func coversEveryKindOfStep() {
        var generator = RandomEventGenerator(seed: 7, includePostingBreaks: true)
        let steps = generator.sequence(length: 5_000)
        var kinds = Set<String>()
        for step in steps {
            switch step {
            case .key(let event): kinds.insert("key.\(event.kind)")
            case .focusChange: kinds.insert("focus")
            case .secureInput: kinds.insert("secure")
            case .permission: kinds.insert("permission")
            case .advanceMicroseconds: kinds.insert("advance")
            case .workerRuns: kinds.insert("worker")
            case .tapDrains: kinds.insert("drain")
            case .postingWorks: kinds.insert("posting")
            }
        }
        let expected: Set<String> = [
            "key.keyDown", "key.keyUp", "key.flagsChanged", "key.leftMouseDown", "key.scrollWheel",
            "key.tapDisabledByTimeout", "focus", "secure", "permission", "advance", "worker", "drain", "posting",
        ]
        #expect(expected.isSubset(of: kinds))
        var plain = RandomEventGenerator(seed: 7)
        #expect(!plain.sequence(length: 5_000).contains { if case .postingWorks = $0 { true } else { false } })
    }
}

extension RandomEventGenerator {
    func sequenceCopy(length: Int) -> [Step] {
        var copy = self
        return copy.sequence(length: length)
    }
}

@Suite struct ConservationLedgerTests {
    private func down(_ code: UInt16 = Key.a) -> RawKeyEvent { PipelineFixtures.keyEvent(.keyDown, code) }
    private func up(_ code: UInt16 = Key.a) -> RawKeyEvent { PipelineFixtures.keyEvent(.keyUp, code) }
    private let record = KeyEventRecord(
        kind: .keyDown, keyCode: KeyCode(rawValue: Key.a), flags: 0, autorepeat: false, keyboardType: 40,
        unicode: .empty, receivedAt: .zero, isProbe: false)

    @Test func cleanRunHasNoViolations() {
        let ledger = ConservationLedger()
        ledger.physical(0, down(), outcome: .passed)
        ledger.passedThrough(0)
        ledger.physical(1, down(), outcome: .consumedForEdit)
        ledger.physical(2, down(Key.d), outcome: .held)
        ledger.editDelivered(forEvent: 1)
        ledger.delivered(record, asReplayOf: 2)
        ledger.physical(3, up(), outcome: .consumedPairedKeyUp)
        ledger.physical(4, up(Key.d), outcome: .passed)
        ledger.passedThrough(4)
        ledger.lostMetric(0)
        #expect(ledger.violations().isEmpty)
    }

    @Test func detectsDropsDuplicatesAndMissingOutcomes() {
        let ledger = ConservationLedger()
        ledger.physical(0, down(), outcome: .passed)  // never delivered
        ledger.physical(1, down(Key.d), outcome: .held)
        ledger.delivered(record, asReplayOf: 1)
        ledger.delivered(record, asReplayOf: 1)  // twice
        ledger.physical(2, down(Key.e), outcome: nil)
        ledger.physical(3, down(Key.s), outcome: .consumedAsHotkey)
        ledger.passedThrough(3)
        ledger.physical(4, down(Key.w), outcome: .consumedForEdit)  // edit never delivered
        #expect(Set(ledger.violations().map(\.eventIndex)).isSuperset(of: [0, 1, 2, 3, 4]))
    }

    /// PLT-R311.
    @Test func detectsOrderingViolations() {
        let ledger = ConservationLedger()
        ledger.physical(0, down(), outcome: .consumedForEdit)
        ledger.physical(1, down(Key.d), outcome: .passed)
        ledger.passedThrough(1)
        ledger.editDelivered(forEvent: 0)  // the edit reached the field after a later key
        #expect(ledger.violations().contains { $0.reason.hasPrefix("ordering") })
    }

    /// PLT-R313.
    @Test func detectsKeyUpPairingViolations() {
        let ledger = ConservationLedger()
        ledger.physical(0, down(), outcome: .passed)
        ledger.passedThrough(0)
        ledger.physical(1, up(), outcome: .consumedPairedKeyUp)  // delivered keyDown, swallowed keyUp
        ledger.physical(2, down(Key.d), outcome: .consumedForEdit)
        ledger.editDelivered(forEvent: 2)
        ledger.physical(3, up(Key.d), outcome: .passed)  // consumed keyDown, delivered keyUp
        ledger.passedThrough(3)
        ledger.physical(4, up(Key.e), outcome: .consumedPairedKeyUp)  // keyUp without keyDown swallowed
        let indices = ledger.violations().map(\.eventIndex)
        #expect(indices.contains(1) && indices.contains(3) && indices.contains(4))
    }

    @Test func failOpenRelaxesPairingAndOrdering() {
        let ledger = ConservationLedger()
        ledger.physical(0, down(), outcome: .consumedForEdit)
        ledger.physical(1, up(), outcome: .passed)
        ledger.processedWhileFailingOpen(1)
        ledger.passedThrough(1)
        ledger.editDelivered(forEvent: 0)
        #expect(ledger.violations().isEmpty)
    }

    /// ADR 0311: losses only after posting broke, and they must match the metric.
    @Test func lossesAreAllowedOnlyAfterPostingBrokeAndMustMatchTheMetric() {
        let early = ConservationLedger()
        early.physical(0, down(), outcome: .held)
        early.lostWhilePostingBroken(0)
        #expect(early.violations().contains { $0.reason.contains("before posting broke") })

        let late = ConservationLedger()
        late.physical(0, down(), outcome: .held)
        late.postingWorks(false)
        late.lostWhilePostingBroken(0)
        late.lostMetric(1)
        #expect(late.violations().isEmpty)
        late.lostMetric(2)
        #expect(late.violations().contains { $0.eventIndex == -1 })
        late.violation(7, "custom")
        #expect(late.violations().contains { $0.description == "event 7: custom" })
    }
}

@Suite struct AllocationCounterTests {
    @Test func countsAllocationsOnTheMeasuredThreadOnly() {
        guard AllocationCounter.isAvailable else { return }  // sanitizer runtimes replace malloc
        let counts = AllocationCounter.measure {
            let array = [Int](repeating: 1, count: 64)
            #expect(array.count == 64)
        }
        #expect(counts.allocations >= 1)
        let paused = AllocationCounter.measure {
            AllocationCounter.pause()
            let array = [Int](repeating: 2, count: 64)
            #expect(array.count == 64)
            AllocationCounter.resume()
        }
        #expect(paused.allocations == 0)
    }
}
