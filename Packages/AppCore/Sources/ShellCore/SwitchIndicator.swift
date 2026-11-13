// SPDX-License-Identifier: GPL-3.0-or-later
//
// Timing and policy of the VI/EN switch HUD (PRD-R12, D14): shown for 600 ms on a manual toggle only, a new
// toggle restarts the timer, never shown for automatic per-app switches. The panel itself lives in App/Shell.

public import AppModel
public import RealtimeSupport

@MainActor
public final class SwitchIndicator {
    /// PRD-R12.
    public static let displayDuration: TimeSpan = .milliseconds(600)
    static let leeway: TimeSpan = .milliseconds(10)

    public enum Change: Sendable, Hashable {
        case show(TypingMode)
        case hide
    }

    public private(set) var visibleMode: TypingMode?
    private let scheduler: any TimerScheduler
    private let onChange: @MainActor (Change) -> Void
    private var timer: (any ScheduledTimer)?
    private var generation: UInt64 = 0

    /// `scheduler` must deliver on the main queue (production: `DispatchTimerScheduler(queue: .main)`; tests:
    /// `ManualScheduler` advanced from the main actor).
    public init(scheduler: any TimerScheduler, onChange: @escaping @MainActor (Change) -> Void) {
        self.scheduler = scheduler
        self.onChange = onChange
    }

    /// D14 policy: the HUD appears only when the setting is on and the switch was manual (PRD-R12).
    public static func shouldShow(manual: Bool, indicatorEnabled: Bool) -> Bool { manual && indicatorEnabled }

    public func modeChanged(to mode: TypingMode, manual: Bool, indicatorEnabled: Bool) {
        guard Self.shouldShow(manual: manual, indicatorEnabled: indicatorEnabled) else { return }
        show(mode)
    }

    public func show(_ mode: TypingMode) {
        timer?.cancel()
        generation &+= 1
        let current = generation
        visibleMode = mode
        onChange(.show(mode))
        timer = scheduler.schedule(after: Self.displayDuration, leeway: Self.leeway) { [weak self] in
            MainActor.assumeIsolated { self?.expire(current) }
        }
    }

    private func expire(_ expected: UInt64) {
        // A timer that fired after a newer `show` belongs to the old presentation.
        guard expected == generation, visibleMode != nil else { return }
        visibleMode = nil
        timer = nil
        onChange(.hide)
    }
}
