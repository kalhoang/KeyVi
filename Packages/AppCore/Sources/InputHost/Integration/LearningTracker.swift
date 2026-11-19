// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R861 learning signals and ENG-R862 (decision of the product owner, 13/11/2026, ADR 0320): learning stays
// automatic after two identical signals, counted per app, and the learned word is stored for that app only. The
// focused app's lists reach the engine through the settings publisher (ENG-R851). Signals are content (raw keys):
// they live in memory only, are never logged and are forgotten at quit (PLT-R911, ADR 0306 decision 6).
// Workstreams W2-A, W5-B.

internal import AppModel
public import SettingsStore
internal import VietnameseEngine

/// Counts identical signals per app; the second one in the same app becomes a proposal for that app.
struct LearningTracker {
    /// Distinct pending signals kept; the oldest is forgotten first.
    static let capacity = 64

    private var pending: [LearningProposal] = []

    /// Returns the proposal when `signal` was seen for the second time in `app`; the count then starts over. A
    /// signal from an unknown app is dropped: a learned word must belong to an app (ENG-R862). So is a signal for a
    /// word of the bundled collision list (`collisionWords`, ENG-R862 amendment of 15/11/2026): those feed the
    /// learned memory, per user across apps, and a per-app list entry would fix them in one direction. A
    /// `neverCorrect` signal is never counted here: one is enough and it applies in every app (ENG-R1118), so the
    /// host stores it at once on its own path.
    mutating func note(
        _ signal: LearningSignal, in app: BundleKey?, collisionWords: CollisionVocabulary? = nil
    ) -> LearningProposal? {
        guard let app, let proposal = LearningProposal(signal, app: app), !proposal.rawKeys.isEmpty else {
            return nil
        }
        if let collisionWords, collisionWords.contains(proposal.rawKeys.lowercased()) { return nil }
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
    /// The per-app proposal of a toggle's signal; nil for `neverCorrect`, which is not a per-app list entry
    /// (ENG-R1118).
    init?(_ signal: LearningSignal, app: BundleKey) {
        switch signal {
        case .preferredRaw(let raw): self.init(list: .keepAsTyped, rawKeys: raw, app: app)
        case .preferredVietnamese(let raw): self.init(list: .keepVietnamese, rawKeys: raw, app: app)
        case .neverCorrect: return nil
        }
    }

    /// Stores the word for `app` (ENG-R862); in that app it leaves the other list, so the newest choice wins
    /// (ENG-R860). The global entries are never changed by learning.
    public func apply(to settings: inout UserSettings) {
        settings.learn(rawKeys, in: list, app: app)
    }
}

extension InputHostController {
    /// ENG-R851, ENG-R862: the focused app changed, so the engines may need that app's learned words. The snapshot
    /// is rebuilt on the utility queue, never on the tap (PLT-R304, PLT-R305), and only when the lists differ.
    func publishWordLists(for app: BundleKey?) {
        let publisher = settingsPublisher
        dependencies.utilityQueue.async { publisher.focusChanged(to: app) }
    }
}
