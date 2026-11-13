// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The rules `ConservationLedger` checks (PLT-R311, PLT-R312, PLT-R313, ADR 0308, ADR 0311).

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
        found += orderingViolations()
        found += pairingViolations()
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
            return delivered + event.edits + event.lost == 0 ? nil : "hotkey delivered \(delivered) times"
        }
    }

    /// PLT-R311: deliveries reach the field in physical order (an edit counts at its trigger's position).
    private func orderingViolations() -> [ConservationLedger.Violation] {
        var found: [ConservationLedger.Violation] = []
        var highest = -1
        for index in order {
            if index < highest {
                found.append(.init(eventIndex: index, reason: "ordering: delivered after event \(highest)"))
            }
            highest = max(highest, index)
        }
        return found
    }

    /// PLT-R313: a keyUp is delivered exactly when the keyDown before it (same key code) was delivered.
    private func pairingViolations() -> [ConservationLedger.Violation] {
        var found: [ConservationLedger.Violation] = []
        var lastDown: [KeyCode: Int] = [:]
        for index in events.keys.sorted() {
            let event = events[index]!
            switch event.event.kind {
            case .keyDown: lastDown[event.event.keyCode] = index
            case .keyUp:
                if let reason = pairing(keyUp: event, keyDown: lastDown[event.event.keyCode].flatMap { events[$0] }) {
                    found.append(.init(eventIndex: index, reason: reason))
                }
            default: break
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
