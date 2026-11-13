// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Apps offered by the bug report sheet's picker (PRD-R47 item 1): the apps of the Apps pane, that is the apps the
// user has typed in from the per-app memory, most recent first, plus apps with a compatibility override (PRD-R34).
// Bundle IDs and display names only: nothing typed, no window titles, no paths (PLT-R1203).

public import AppModel
public import SettingsStore

public enum RecentReportApps {
    /// The picker lists at most this many apps.
    public static let limit = 20
    /// Display names are cut to this many characters.
    public static let maximumNameLength = 80

    /// The Apps pane's apps in its order (`AppsPaneModel.orderedBundles`), without this app (`own` is the running
    /// bundle's identifier, compared without case as LaunchServices does) and without keys of processes that have
    /// no bundle ID (`sha256:`), at most `limit`. `name` resolves the installed app's display name; a missing or
    /// blank name falls back to the bundle ID.
    public static func choices(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], excluding own: String?, limit: Int = limit,
        name: (BundleKey) -> String?
    ) -> [BugReportAppChoice] {
        let bundles = AppsPaneModel.orderedBundles(appModes: appModes, overrides: overrides)
            .filter { offerable($0, excluding: own) }
            .prefix(max(0, limit))
        return bundles.map { BugReportAppChoice(bundle: $0, name: displayName(name($0), fallback: $0)) }
    }

    /// The app to preselect, "the last frontmost app" (PRD-R47 item 1). From the status menu the focused app is the
    /// app the user was typing in, because opening the menu does not activate this app. When the report starts in
    /// one of this app's own windows (Settings, Diagnostics), the most recent other app of `recent` stands in.
    public static func preselection(
        focused: BundleKey?, recent: [BugReportAppChoice], excluding own: String?, name: (BundleKey) -> String?
    ) -> BugReportAppChoice? {
        guard let focused, offerable(focused, excluding: own) else { return recent.first }
        return recent.first { $0.bundle == focused }
            ?? BugReportAppChoice(bundle: focused, name: displayName(name(focused), fallback: focused))
    }

    static func offerable(_ bundle: BundleKey, excluding own: String?) -> Bool {
        guard !bundle.isExecutableHash else { return false }
        guard let own else { return true }
        return bundle.rawValue.lowercased() != own.lowercased()
    }

    /// One line of at most `maximumNameLength` characters: control characters and line or paragraph separators
    /// become spaces, runs of white space collapse, surrounding white space is trimmed.
    static func displayName(_ raw: String?, fallback: BundleKey) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in (raw ?? "").unicodeScalars {
            let isSpace: Bool =
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator: true
                default: false
                }
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
            } else {
                scalars.append(scalar)
            }
            lastWasSpace = isSpace
        }
        var name = String(scalars)
        if name.last == " " { name.removeLast() }
        guard !name.isEmpty else { return fallback.rawValue }
        return String(name.prefix(maximumNameLength))
    }
}
