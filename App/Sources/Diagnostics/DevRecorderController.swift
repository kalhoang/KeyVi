// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dev builds' typing recorder in the running app (PLT-R904A, ADR 0007; Pa, 2026-11-14): always on from launch,
// the field readback, settings and mode notes, the marker confirmation (the menu bar icon flashes for 1 s and
// VoiceOver announces it, without taking focus), pause and resume, and the log folder. Debug configuration only:
// Release never compiles this file (and excludes it by name, project.yml), and scripts/verify-release.sh proves
// the recorder is absent from a release.

#if DEV_RECORDER
import AppKit
import AppModel
import Diagnostics
import Foundation
import InputHost
import SettingsStore
import ShellCore

@MainActor
final class DevRecorderController: NSObject {
    /// How long the icon shows the marker confirmation.
    static let flashDuration: TimeInterval = 1

    let recorder: DevRecorder
    private let attentionQueue: DispatchQueue
    private var readback: DevReadback?
    private var lastSettings: DevSettingsSnapshot?
    private var flashTimer: Timer?
    private var resumeTimer: Timer?
    /// The icon shows the marker confirmation.
    private(set) var isFlashing = false
    /// Redraws the status item's badge (recording, paused, flashing).
    var indicatorChanged: (@MainActor () -> Void)?
    /// Posts the marker announcement from the status item (PRD-R66).
    var announce: (@MainActor (String) -> Void)?
    var localizer: (@MainActor () -> Localizer)?

    init(recorder: DevRecorder, attentionQueue: DispatchQueue) {
        self.recorder = recorder
        self.attentionQueue = attentionQueue
    }

    /// Recording while started and not paused (or in a secure gap): the badge shows.
    var isRecording: Bool { recorder.isStarted && recorder.pausedUntil == nil }

    /// Once the shell exists: start without asking (PLT-R904A), the readback, the settings and the focus in effect.
    func start(appVersion: String, host: InputHostController, settings: SettingsState) {
        do {
            try recorder.start(appVersion: appVersion)
        } catch {
            indicatorChanged?()
            return
        }
        readback = host.startDevReadback(queue: attentionQueue)
        recorder.addAttentionListener { [weak self] reasons in
            guard reasons.contains(.marker) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.confirmMarker() } }
        }
        lastSettings = nil  // changes seen before the start were not written
        noteSettings(settings)
        recorder.note(.focus(host.devFocusRecord()))
        indicatorChanged?()
    }

    func noteSettings(_ state: SettingsState) {
        let snapshot = DevRecorderSettings.snapshot(state)
        guard snapshot != lastSettings else { return }
        lastSettings = snapshot
        recorder.noteSettings(snapshot)
    }

    func noteMode(_ mode: TypingMode, manual: Bool, bundle: BundleKey?) {
        recorder.noteMode(mode, manual: manual, bundle: bundle?.rawValue)
    }

    // MARK: Menu actions

    @objc func mark(_ sender: Any?) { recorder.mark(source: .menu) }

    @objc func pause(_ sender: Any?) {
        recorder.pause()
        resumeTimer?.invalidate()
        // The recorder resumes on its own queue; the badge follows a moment later.
        let seconds = DevRecorderLimits.pauseDuration.inSeconds + 1
        resumeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.indicatorChanged?() }
        }
        indicatorChanged?()
    }

    @objc func resume(_ sender: Any?) {
        recorder.resume()
        resumeTimer?.invalidate()
        resumeTimer = nil
        indicatorChanged?()
    }

    @objc func openFolder(_ sender: Any?) {
        let folder = recorder.directory
        let target = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        NSWorkspace.shared.open(target)
    }

    // MARK: Marker confirmation

    /// About 1 s of a different badge, plus a VoiceOver announcement; never a window, never focus.
    private func confirmMarker() {
        isFlashing = true
        indicatorChanged?()
        if let localizer = localizer?() { announce?(localizer.string(DevRecorderText.markedAnnouncement)) }
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isFlashing = false
                self?.indicatorChanged?()
            }
        }
    }
}
#endif
