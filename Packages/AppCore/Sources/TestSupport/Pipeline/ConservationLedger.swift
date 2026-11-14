// SPDX-License-Identifier: GPL-3.0-or-later
//
// The rules `ConservationLedger` checks (PLT-R311, PLT-R312, PLT-R313, ADR 0308, ADR 0311, ADR 0322).

internal import AppModel
internal import Injection
internal import InputHost

struct LedgerState {
    private struct Physical {
        var event: RawKeyEvent
        var outcome: EventOutcome?
        var failingOpen = false
        var passes = 0
        var replays = 0
        var edits = 0
        var lost = 0
    }

    private enum Delivery {
        case delivered(Int)
        case failOpenPass(Int)
    }

    private var events: [Int: Physical] = [:]
    /// Deliveries in the order they reached the field, while posting worked and before it first broke.
    private var order: [Int] = []
    private var postingEverBroke = false
    private var lostTotal: UInt64 = 0
    private var extraViolations: [ConservationLedger.Violation] = []
    var lostMetric: UInt64?

    mutating func physical(_ index: Int, _ event: RawKeyEvent, outcome: EventOutcome?) {
        events[index, default: Physical(event: event)].event = event
        events[index]?.outcome = outcome
    }

    mutating func failingOpen(_ index: Int) { events[index]?.failingOpen = true }

    mutating func passedThrough(_ index: Int) {
        events[index]?.passes += 1
        noteOrder(index)
    }

    mutating func delivered(_ record: KeyEventRecord, asReplayOf index: Int) {
        events[index]?.replays += 1
        noteOrder(index)
    }

    mutating func editDelivered(_ index: Int) {
        events[index]?.edits += 1
        noteOrder(index)
    }

    mutating func lost(_ index: Int) {
        lostTotal += 1
        events[index]?.lost += 1
        // "No event is lost before the switch": losses are allowed only once posting has broken in this run;
        // after recovery, jobs posted into the void may still be counted.
        if !postingEverBroke { extra(index, "lost before posting broke") }
    }

    mutating func postingWorks(_ works: Bool) {
        if !works { postingEverBroke = true }
    }

    mutating func extra(_ index: Int, _ reason: String) {
        extraViolations.append(ConservationLedger.Violation(eventIndex: index, reason: reason))
    }

    private mutating func noteOrder(_ index: Int) {
        guard !postingEverBroke, let event = events[index], !event.failingOpen || event.outcome != .passed else {
            return
        }
        order.append(index)
    }

    func violations() -> [ConservationLedger.Violation] {
        var found = extraViolations
        for index in events.keys.sorted() {
            if let reason = outcomeViolation(events[index]!) { found.append(.init(eventIndex: index, reason: reason)) }
        }
        let keyDowns = keyDownBeforeEachKeyUp()
        let passedKeyUps = keyUpsOfPassedKeyDowns(keyDowns)
        found += passedKeyUpViolations(passedKeyUps)
        found += orderingViolations(passedKeyUps: passedKeyUps, keyDowns: keyDowns)
        found += pairingViolations(keyDowns)
        if let lostMetric, lostMetric != lostTotal {
            found.append(.init(eventIndex: -1, reason: "lost \(lostTotal) events but the metric says \(lostMetric)"))
        }
        return found
    }

    /// PLT-R312: one outcome, delivered at most once, by the means the outcome promises.
    private func outcomeViolation(_ event: Physical) -> String? {
        let delivered = event.passes + event.replays
        switch event.outcome {
        case nil:
            return "physical keyboard event has no outcome (treated as an echo, PLT-R321)"
        case .passed?:
            return event.passes == 1 && event.replays + event.edits + event.lost == 0
                ? nil : "passed but delivered \(delivered) times, edits \(event.edits), lost \(event.lost)"
        case .held?:
            // The edit of a thenPassThrough key may precede the replay (P0-3).
            return event.passes == 0 && event.replays + event.lost == 1 && event.edits <= 1
                ? nil : "held but replayed \(event.replays) times, passed \(event.passes), lost \(event.lost)"
        case .consumedForEdit?:
            // Edit delivered, or the job was abandoned and the trigger replayed (ADR 0308), or lost.
            return event.passes == 0 && event.edits + event.replays + event.lost == 1
                ? nil : "consumed for an edit but edits \(event.edits), replays \(event.replays), lost \(event.lost)"
        case .consumedPairedKeyUp?:
            return event.passes + event.edits == 0 && event.replays + event.lost <= 1
                ? nil : "paired keyUp delivered \(delivered) times"
        case .consumedAsHotkey?:
            // Never delivered itself; the restore binding (PLT-R353) may carry its edit, which can be lost too.
            return delivered == 0 && event.edits + event.lost <= 1
                ? nil : "hotkey delivered \(delivered) times, edits \(event.edits), lost \(event.lost)"
        }
    }

    /// keyUp index -> the last keyDown (autorepeat included) of the same key code before it that no earlier keyUp
    /// already paired with (the pipeline forgets a pairing at the first keyUp, `ConsumedKeyTable.take`).
    private func keyDownBeforeEachKeyUp() -> [Int: Int] {
        var lastDown: [KeyCode: Int] = [:]
        var pairs: [Int: Int] = [:]
        for index in events.keys.sorted() {
            let event = events[index]!
            switch event.event.kind {
            case .keyDown: lastDown[event.event.keyCode] = index
            case .keyUp: pairs[index] = lastDown.removeValue(forKey: event.event.keyCode)
            default: break
            }
        }
        return pairs
    }

    /// PLT-R311 amendment (ADR 0322): keyUps whose keyDown passed unchanged. They pass at once, even while jobs are
    /// in flight, so they are out of the cross-key order.
    private func keyUpsOfPassedKeyDowns(_ keyDowns: [Int: Int]) -> Set<Int> {
        Set(keyDowns.compactMap { keyUp, keyDown in events[keyDown]?.outcome == .passed ? keyUp : nil })
    }

    /// ADR 0322: the app got the keyboard's keyDown, so it must get the keyboard's keyUp, never a replay.
    private func passedKeyUpViolations(_ passedKeyUps: Set<Int>) -> [ConservationLedger.Violation] {
        passedKeyUps.sorted().compactMap { index in
            guard let keyUp = events[index], !keyUp.failingOpen, keyUp.outcome == .held || keyUp.replays > 0 else {
                return nil
            }
            return .init(eventIndex: index, reason: "replayed keyUp of a passed keyDown")
        }
    }

    /// PLT-R311: deliveries reach the field in physical order (an edit counts at its trigger's position). The keyUp
    /// of a passed keyDown is exempt from that order but must still come after its own keyDown (ADR 0322).
    private func orderingViolations(passedKeyUps: Set<Int>, keyDowns: [Int: Int]) -> [ConservationLedger.Violation] {
        var found: [ConservationLedger.Violation] = []
        var highest = -1
        var deliveredSoFar: Set<Int> = []
        let deliveredAtAll = Set(order)
        for index in order {
            defer { deliveredSoFar.insert(index) }
            if passedKeyUps.contains(index) {
                if let keyDown = keyDowns[index], deliveredAtAll.contains(keyDown), !deliveredSoFar.contains(keyDown) {
                    found.append(.init(eventIndex: index, reason: "ordering: keyUp delivered before its own keyDown"))
                }
                continue
            }
            if index < highest {
                found.append(.init(eventIndex: index, reason: "ordering: delivered after event \(highest)"))
            }
            highest = max(highest, index)
        }
        return found
    }

    /// PLT-R313: a keyUp is delivered exactly when the keyDown before it (same key code) was delivered.
    private func pairingViolations(_ keyDowns: [Int: Int]) -> [ConservationLedger.Violation] {
        var found: [ConservationLedger.Violation] = []
        for index in events.keys.sorted() where events[index]!.event.kind == .keyUp {
            if let reason = pairing(keyUp: events[index]!, keyDown: keyDowns[index].flatMap { events[$0] }) {
                found.append(.init(eventIndex: index, reason: reason))
            }
        }
        return found
    }

    private func pairing(keyUp: Physical, keyDown: Physical?) -> String? {
        if keyUp.lost > 0 || keyDown.map({ $0.lost > 0 }) == true { return nil }  // posting broke: counted
        let upDelivered = keyUp.passes + keyUp.replays > 0
        guard let keyDown else { return upDelivered ? nil : "keyUp without keyDown was not delivered" }
        let downDelivered = keyDown.passes + keyDown.replays > 0
        if downDelivered && !upDelivered { return "keyDown delivered but its keyUp was swallowed" }
        if !downDelivered && upDelivered && !keyUp.failingOpen { return "keyDown consumed but its keyUp was delivered" }
        return nil
    }
}
