// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed keys of the `Composition` String Catalog (ADR 0310): the composition root's own notices, safe mode
// (PLT-R1009), a failed move to Applications (PLT-R710) and the once-per-launch conflict warning (PLT-R399).
// The keys live here, next to the shell's other tables, so the catalog test covers them; the App reads them
// through the shared `Localizer`.

/// `Composition` table keys used by `CompositionAlerts` (App/Sources/Composition).
public enum CompositionText: String, LocalizationKey {
    public static var table: StringTable { .composition }

    case safeModeTitle = "safeMode.title"
    case safeModeBody = "safeMode.body"
    case safeModeReset = "safeMode.reset"
    case safeModeResetHint = "safeMode.reset.hint"
    case safeModeExit = "safeMode.exit"
    case safeModeExitHint = "safeMode.exit.hint"
    case safeModeReport = "safeMode.report"
    case safeModeReportHint = "safeMode.report.hint"
    case safeModeLater = "safeMode.later"
    case safeModeLaterHint = "safeMode.later.hint"
    case moveFailedTitle = "move.failed.title"
    case moveFailedBody = "move.failed.body"
    case moveFailedQuit = "move.failed.quit"
    case moveFailedQuitHint = "move.failed.quit.hint"
    case conflictsHelpHint = "conflicts.help.hint"
    case conflictsDismiss = "conflicts.dismiss"
    case conflictsDismissHint = "conflicts.dismiss.hint"
    case conflictsOpenKeyboardHint = "conflicts.openKeyboard.hint"
}
