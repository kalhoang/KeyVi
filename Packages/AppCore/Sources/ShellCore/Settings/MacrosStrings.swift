// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed keys of the `Macros` String Catalog (ADR 0310, PRD-R62, PRD-R66): Macros pane, editor and import preview
// (PRD-R29-R33). A catalog test checks that every key exists in vi and en with matching arguments and that the
// catalog holds no dead copy.

/// `Macros` table keys.
public enum MacrosText: String, LocalizationKey {
    public static var table: StringTable { .macros }

    case enabledTitle = "macros.enabled.title"
    case enabledExplanation = "macros.enabled.explanation"
    case empty = "macros.empty"
    case add = "macros.add"
    case importFile = "macros.import"
    case exportFile = "macros.export"
    case searchPlaceholder = "macros.search.placeholder"
    case noResults = "macros.search.noResults"
    case count = "macros.count"
    case sortTitle = "macros.sort.title"
    case sortOrderAdded = "macros.sort.orderAdded"
    case sortShortcut = "macros.sort.shortcut"
    case sortExpansion = "macros.sort.expansion"
    case columnEnabled = "macros.column.enabled"
    case columnShortcut = "macros.column.shortcut"
    case columnExpansion = "macros.column.expansion"
    case edit = "macros.edit"
    case duplicate = "macros.duplicate"
    case delete = "macros.delete"
    case enableAll = "macros.enableAll"
    case disableAll = "macros.disableAll"
    case deleteTitle = "macros.delete.title"
    case deleteConfirm = "macros.delete.confirm"
    case deleteCancel = "macros.delete.cancel"
    case editorTitleAdd = "macros.editor.title.add"
    case editorTitleEdit = "macros.editor.title.edit"
    case editorShortcut = "macros.editor.shortcut"
    case editorShortcutHelp = "macros.editor.shortcut.help"
    case editorExpansion = "macros.editor.expansion"
    case editorExpansionHelp = "macros.editor.expansion.help"
    case editorAdaptCase = "macros.editor.adaptCase"
    case editorAdaptCaseHelp = "macros.editor.adaptCase.help"
    case editorEnabled = "macros.editor.enabled"
    case editorSave = "macros.editor.save"
    case editorCancel = "macros.editor.cancel"
    case issueEmptyShortcut = "macros.issue.emptyShortcut"
    case issueEmptyExpansion = "macros.issue.emptyExpansion"
    case issueShortcutTooLong = "macros.issue.shortcutTooLong"
    case issueShortcutWhitespace = "macros.issue.shortcutWhitespace"
    case issueShortcutNotASCII = "macros.issue.shortcutNotASCII"
    case issueExpansionTooLong = "macros.issue.expansionTooLong"
    case issueShadowedBy = "macros.issue.shadowedBy"
    case issueShadows = "macros.issue.shadows"
    case issueDuplicate = "macros.issue.duplicate"
    case issueMalformedLine = "macros.issue.malformedLine"
    case issueLine = "macros.issue.line"
    case issueEntry = "macros.issue.entry"
    case warningTelexDigit = "macros.warning.telexDigit"
    case saveFailed = "macros.saveFailed"
    case importTitle = "macros.import.title"
    case importNew = "macros.import.new"
    case importDuplicates = "macros.import.duplicates"
    case importInvalid = "macros.import.invalid"
    case importDuplicateChoice = "macros.import.duplicateChoice"
    case importKeepMine = "macros.import.keepMine"
    case importUseImported = "macros.import.useImported"
    case importConfirm = "macros.import.confirm"
    case importCancel = "macros.import.cancel"
    case importChooseOther = "macros.import.chooseOther"
    case importInvalidFile = "macros.import.invalidFile"
    case importInvalidFileLine = "macros.import.invalidFileLine"
    case importTooLarge = "macros.import.tooLarge"
    case importUnreadable = "macros.import.unreadable"
    case importEmpty = "macros.import.empty"
    case importDone = "macros.import.done"
    case exportFailed = "macros.export.failed"
}

/// Every interactive control that uses the `Macros` table, with its VoiceOver label and hint (PRD-R66).
public enum MacrosControl: String, AccessibleControl {
    public static var table: StringTable { .macros }
    public static var keyPrefix: String { "macros" }

    case enabled
    case search
    case sort
    case add
    case importFile
    case exportFile
    case enableAll
    case disableAll
    case list
    case rowEnabled
    case rowEdit
    case rowDuplicate
    case rowDelete
    case deleteConfirm
    case deleteCancel
    case editorShortcut
    case editorExpansion
    case editorAdaptCase
    case editorEnabled
    case editorSave
    case editorCancel
    case importDuplicateChoice
    case importConfirm
    case importCancel
    case importChooseOther
    case resetPane
}
