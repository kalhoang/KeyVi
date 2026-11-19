// SPDX-License-Identifier: GPL-3.0-or-later
//
// The shell side of the dev builds' typing recorder (PLT-R904A, ADR 0007), without AppKit: the copy keys of the
// DevRecorder catalog, the status menu entries (recording or paused until a time), and the settings snapshot the
// recorder writes at the top of every file and on every change. Debug configuration only.

#if DEV_RECORDER
public import Diagnostics
public import Foundation
public import SettingsStore
internal import AppModel

/// `DevRecorder` catalog keys (vi and en).
public enum DevRecorderText: String, LocalizationKey {
    public static var table: StringTable { .devRecorder }

    case statusRecording = "devRecorder.status.recording"
    /// Argument: the time the pause ends, in the interface language.
    case statusPaused = "devRecorder.status.paused"
    case statusHint = "devRecorder.status.accessibilityHint"
    case mark = "devRecorder.mark"
    case markHint = "devRecorder.mark.accessibilityHint"
    case pause = "devRecorder.pause"
    case pauseHint = "devRecorder.pause.accessibilityHint"
    case resume = "devRecorder.resume"
    case resumeHint = "devRecorder.resume.accessibilityHint"
    case openFolder = "devRecorder.openFolder"
    case openFolderHint = "devRecorder.openFolder.accessibilityHint"
    /// Appended to the status item's VoiceOver label while the badge shows.
    case badgeLabel = "devRecorder.badge.accessibilityLabel"
    /// Announced when a marker was recorded.
    case markedAnnouncement = "devRecorder.marked.announcement"
}

/// The dev entries at the top of the status menu.
public enum DevRecorderMenuEntry: Sendable, Hashable {
    /// Disabled line: recording, or paused until the given time.
    case status(pausedUntil: Date?)
    case mark
    case pause
    case resume
    case openFolder

    /// Status line, marker, pause or resume, open folder; nothing when the recorder did not start.
    public static func entries(isStarted: Bool, pausedUntil: Date?) -> [DevRecorderMenuEntry] {
        guard isStarted else { return [.openFolder] }
        return [.status(pausedUntil: pausedUntil), .mark, pausedUntil == nil ? .pause : .resume, .openFolder]
    }

    public func title(_ localizer: Localizer) -> String {
        switch self {
        case .status(let until?):
            localizer.format(DevRecorderText.statusPaused, Self.time(until, localizer: localizer))
        case .status(nil): localizer.string(DevRecorderText.statusRecording)
        case .mark: localizer.string(DevRecorderText.mark)
        case .pause: localizer.string(DevRecorderText.pause)
        case .resume: localizer.string(DevRecorderText.resume)
        case .openFolder: localizer.string(DevRecorderText.openFolder)
        }
    }

    public var accessibilityHintKey: DevRecorderText {
        switch self {
        case .status: .statusHint
        case .mark: .markHint
        case .pause: .pauseHint
        case .resume: .resumeHint
        case .openFolder: .openFolderHint
        }
    }

    /// `HH:mm` in Vietnamese, `h:mm AM` in English (PRD-R65: times in the selected language).
    static func time(_ date: Date, localizer: Localizer, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: localizer.locale, timeZone: timeZone))
    }
}

/// The settings the recorder writes (PLT-R904A): everything that changes engine output or how the host treats keys,
/// as names and values. Word lists and macros are counted, never copied (user content stays in settings.json).
public enum DevRecorderSettings {
    public static func snapshot(_ state: SettingsState) -> DevSettingsSnapshot {
        let settings = state.effective
        let values: [String: String] = [
            "typingMethod": settings.typingMethod.rawValue,
            "tonePlacement": settings.tonePlacement.rawValue,
            "englishRestore": String(settings.englishRestore),
            "telexStandaloneW": String(settings.telexStandaloneW),
            "telexBracketKeys": String(settings.telexBracketKeys),
            "macrosEnabled": String(settings.macrosEnabled),
            "macrosInEnglishMode": String(settings.macrosInEnglishMode),
            "typoCorrection": String(settings.typoCorrection),  // D30 (1.1.0): replay rebuilds the switch, ENG-R1119
            "enabledMacros": String(state.macros.filter(\.enabled).count),
            "restoreHotkey": settings.restoreHotkey.map { String(describing: $0) } ?? "none",
            "toggleHotkey": String(describing: settings.toggleHotkey),
            "rememberPerApp": String(settings.rememberPerApp),
            "firstSeenAppMode": String(describing: settings.firstSeenAppMode),
            "layoutBinding": String(describing: settings.layoutBinding),
            "keepAsTypedCount": String(settings.keepAsTyped.count),
            "keepVietnameseCount": String(settings.keepVietnamese.count),
            "optedInRules": settings.optedInRules.map(\.rawValue).sorted().joined(separator: ","),
            "ruleOverrides": String(state.ruleOverrides.count),
            "globalMode": state.appModes.globalMode.rawValue,
            "safeMode": String(state.safeMode),
        ]
        return DevSettingsSnapshot(values: values)
    }
}
#endif
