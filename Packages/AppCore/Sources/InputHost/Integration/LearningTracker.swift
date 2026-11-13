// SPDX-License-Identifier: LicenseRef-App-Pending
//
// ENG-R861 learning signals and open decision 8 ("automatic after two identical signals, visible and
// removable", docs/decisions/0001-defaults-for-open-decisions.md). Signals are content (raw keys): they live in
// memory only, are never logged and are forgotten at quit (PLT-R911, ADR 0306 decision 6). Workstream W2-A.

public import SettingsStore
internal import VietnameseEngine

/// Counts identical signals; the second one becomes a proposal the host applies to the user list.
struct LearningTracker {
    /// Distinct pending signals kept; the oldest is forgotten first.
    static let capacity = 64

    private var pending: [LearningProposal] = []

    /// Returns the proposal when `signal` was seen for the second time; the count then starts over.
    mutating func note(_ signal: LearningSignal) -> LearningProposal? {
        let proposal = LearningProposal(signal)
        guard !proposal.rawKeys.isEmpty else { return nil }
        if let index = pending.firstIndex(of: proposal) {
            pending.remove(at: index)
            return proposal
        }
        pending.append(proposal)
        if pending.count > Self.capacity { pending.removeFirst() }
        return nil
    }
}

extension LearningProposal {
    init(_ signal: LearningSignal) {
        switch signal {
        case .preferredRaw(let raw): self.init(list: .keepAsTyped, rawKeys: raw)
        case .preferredVietnamese(let raw): self.init(list: .keepVietnamese, rawKeys: raw)
        }
    }

    /// Adds the word to its list and removes it from the opposite one, so the newest choice wins (ENG-R860).
    public func apply(to settings: inout UserSettings) {
        switch list {
        case .keepAsTyped:
            settings.keepAsTyped.insert(rawKeys)
            settings.keepVietnamese.remove(rawKeys)
        case .keepVietnamese:
            settings.keepVietnamese.insert(rawKeys)
            settings.keepAsTyped.remove(rawKeys)
        }
    }
}
