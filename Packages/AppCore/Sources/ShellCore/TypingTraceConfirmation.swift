// SPDX-License-Identifier: GPL-3.0-or-later
//
// The "Record typing trace..." confirmation (PLT-R905, D26): the duration choices and the message, which states
// the duration currently chosen in the picker, so the user confirms exactly the duration that will be recorded.

/// State of the confirmation alert: the app name and the chosen duration.
public struct TypingTraceConfirmation: Sendable, Hashable {
    /// Seconds: the PLT-R905 default (60 s) first, the maximum (180 s) last.
    public static let durations = [60, 120, 180]

    public let appName: String
    public private(set) var selectedIndex = 0

    /// `appName` comes from the brand files (the app name is always a format argument).
    public init(appName: String) {
        self.appName = appName
    }

    public var selectedSeconds: Int { Self.durations[selectedIndex] }

    /// The picker's selection. An index outside the choices (an `NSPopUpButton` with no selection reports -1)
    /// keeps the choice on screen.
    public mutating func select(index: Int) {
        guard Self.durations.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Picker titles, in the order of `durations`.
    public func durationTitles(_ localizer: Localizer) -> [String] {
        Self.durations.map { localizer.format(DiagnosticsText.traceSeconds, $0) }
    }

    /// The explanation of what is recorded, for the chosen duration.
    public func message(_ localizer: Localizer) -> String {
        localizer.format(DiagnosticsText.traceConfirmMessage, appName, selectedSeconds)
    }
}
