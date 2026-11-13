// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed keys of the `Diagnostics` String Catalog (ADR 0310), the controls of the Diagnostics windows with their
// VoiceOver keys (PRD-R66, PRD-R67) and the helpers that compose Diagnostics copy from typed values
// (PLT-R1201, PLT-R1205, PLT-R810, PLT-R905, PRD-R47-R49).

public import AppModel
public import Diagnostics

/// `Diagnostics` table keys (PLT-R1201, PLT-R1205, PLT-R810, PLT-R905, PRD-R47-R49). Views and models
/// refer to copy only through these cases, so the catalog test can check every key in vi and en.
public enum DiagnosticsText: String, LocalizationKey {
    public static var table: StringTable { .diagnostics }

    case windowTitle = "diagnostics.window.title"
    case stateLabel = "diagnostics.state.label"
    case stateReadyVietnamese = "diagnostics.state.readyVietnamese"
    case stateReadyEnglish = "diagnostics.state.readyEnglish"
    case stateStarting = "diagnostics.state.starting"
    case stateNoPermission = "diagnostics.state.noPermission"
    case statePausedSecureInput = "diagnostics.state.paused.secureInput"
    case statePausedNonLatin = "diagnostics.state.paused.nonLatinInputSource"
    case statePausedBuiltIn = "diagnostics.state.paused.builtInVietnameseSource"
    case statePausedRule = "diagnostics.state.paused.passThroughRule"
    case statePausedSecureField = "diagnostics.state.paused.secureField"
    case statePausedSession = "diagnostics.state.paused.sessionInactive"
    case statePausedUser = "diagnostics.state.paused.userDisabled"
    case statePausedNoText = "diagnostics.state.paused.noTextFocus"
    case statePausedDiagnosticsTest = "diagnostics.state.paused.diagnosticsTest"
    case stateFailPermission = "diagnostics.state.failOpen.permissionRevoked"
    case stateFailPosting = "diagnostics.state.failOpen.postingBroken"
    case stateFailTap = "diagnostics.state.failOpen.tapUnavailable"
    case stateFailWatchdog = "diagnostics.state.failOpen.watchdog"
    case stateFailStuck = "diagnostics.state.failOpen.callbackStuck"
    case reportHeading = "diagnostics.report.heading"
    case reportNote = "diagnostics.report.note"
    case copyReport = "diagnostics.copyReport"
    case misbehaves = "diagnostics.misbehaves"
    case recordTrace = "diagnostics.recordTrace"
    case latencyTest = "diagnostics.latencyTest"
    case openLogs = "diagnostics.openLogs"
    case copied = "diagnostics.copied"
    case clipboardNotice = "diagnostics.clipboardNotice"
    case logsUnavailable = "diagnostics.logsUnavailable"
    case sheetTitle = "bugReport.title"
    case appLabel = "bugReport.app.label"
    case appNone = "bugReport.app.none"
    case symptomLabel = "bugReport.symptom.label"
    case descriptionLabel = "bugReport.description.label"
    case descriptionNote = "bugReport.description.hint"
    case previewDisclosure = "bugReport.preview.disclosure"
    case practiceButton = "bugReport.practiceField.button"
    case practiceLabel = "bugReport.practiceField.label"
    case practiceYes = "bugReport.practiceField.yes"
    case practiceNo = "bugReport.practiceField.no"
    case practiceUnknown = "bugReport.practiceField.unknown"
    case github = "bugReport.github"
    case email = "bugReport.email"
    case saveFile = "bugReport.saveFile"
    case openDiagnostics = "bugReport.openDiagnostics"
    case githubPasteHint = "bugReport.github.pasteHint"
    case emailFallback = "bugReport.email.fallback"
    case emailUnavailable = "bugReport.email.unavailable"
    case saved = "bugReport.saved"
    case saveFailed = "bugReport.saveFailed"
    case practiceTitle = "practiceField.title"
    case practiceInstructions = "practiceField.instructions"
    case misbehavesTitle = "misbehaves.title"
    case detectedApp = "misbehaves.detected.app"
    case detectedField = "misbehaves.detected.field"
    case detectedRule = "misbehaves.detected.rule"
    case detectedStrategy = "misbehaves.detected.strategy"
    case unknownValue = "misbehaves.unknown"
    case guidedOffer = "misbehaves.guided.offer"
    case guidedExplain = "misbehaves.guided.explain"
    case confirmText = "misbehaves.confirm.text"
    case confirmButton = "misbehaves.confirm.button"
    case testing = "misbehaves.testing"
    case ask = "misbehaves.ask"
    case answerYes = "misbehaves.ask.yes"
    case answerNo = "misbehaves.ask.no"
    case resultFound = "misbehaves.result.found"
    case resultNone = "misbehaves.result.none"
    case resultNotReproduced = "misbehaves.result.notReproduced"
    case ownAppFocused = "misbehaves.ownApp"
    case interruptedFocus = "misbehaves.interrupted.focusChanged"
    case interruptedNotEmpty = "misbehaves.interrupted.fieldNotEmpty"
    case interruptedCancelled = "misbehaves.interrupted.cancelled"
    case includePageAddress = "misbehaves.pageAddress.include"
    case pageAddressField = "misbehaves.pageAddress.field"
    case pageAddressPreview = "misbehaves.pageAddress.preview"
    case suggestionHeading = "misbehaves.suggestion.heading"
    case useForMe = "misbehaves.useForMe"
    case copySuggestion = "misbehaves.copySuggestion"
    case openGitHubIssue = "misbehaves.openGitHubIssue"
    case applied = "misbehaves.applied"
    case stopTest = "misbehaves.stop"
    case strategyBackspaceReplace = "strategy.backspaceReplace"
    case strategySelectReplace = "strategy.selectReplace"
    case strategyAXReplace = "strategy.axReplace"
    case strategyPaste = "strategy.paste"
    case strategyPassThrough = "strategy.passThrough"
    case handlingAXSelection = "strategy.inlineCompletion.axSelection"
    case handlingPlaceholder = "strategy.inlineCompletion.placeholder"
    case handlingBoth = "strategy.inlineCompletion.axSelectionThenPlaceholder"
    case candidateHandling = "strategy.withHandling"
    case candidatePacing = "strategy.withPacing"
    case traceConfirmTitle = "trace.confirm.title"
    case traceConfirmMessage = "trace.confirm.message"
    case traceDuration = "trace.duration"
    case traceSeconds = "trace.duration.seconds"
    case traceStart = "trace.confirm.start"
    case traceReviewTitle = "trace.review.title"
    case traceReviewNote = "trace.review.note"
    case traceExport = "trace.review.export"
    case traceDiscard = "trace.review.discard"
    case traceExported = "trace.exported"
    case traceAlreadyRecording = "trace.error.alreadyRecording"
    case traceInvalidDuration = "trace.error.invalidDuration"
    case traceUnknownSession = "trace.error.unknownSession"
    case traceStorage = "trace.error.storage"
    case probeTitle = "probe.title"
    case probeInstructions = "probe.instructions"
    case probeStart = "probe.start"
    case probeRunning = "probe.running"
    case probeNormal = "probe.profile.normal"
    case probeFast = "probe.profile.fast"
    case probeBurst = "probe.profile.burst"
    case probeResult = "probe.result"
    case probeUnavailable = "probe.unavailable"
    case probeDone = "probe.done"
    case probeStopped = "probe.stopped"
    case probeField = "probe.field"
    case copyReportHint = "diagnostics.copyReport.accessibilityHint"
    case misbehavesHint = "diagnostics.misbehaves.accessibilityHint"
    case recordTraceHint = "diagnostics.recordTrace.accessibilityHint"
    case latencyTestHint = "diagnostics.latencyTest.accessibilityHint"
    case openLogsHint = "diagnostics.openLogs.accessibilityHint"
    case reportTextHint = "diagnostics.report.accessibilityHint"
    case appPickerHint = "bugReport.app.accessibilityHint"
    case symptomHint = "bugReport.symptom.accessibilityHint"
    case descriptionHint = "bugReport.description.accessibilityHint"
    case previewDisclosureHint = "bugReport.preview.accessibilityHint"
    case practiceButtonHint = "bugReport.practiceField.button.accessibilityHint"
    case practiceAnswerHint = "bugReport.practiceField.answer.accessibilityHint"
    case githubHint = "bugReport.github.accessibilityHint"
    case emailHint = "bugReport.email.accessibilityHint"
    case saveFileHint = "bugReport.saveFile.accessibilityHint"
    case openDiagnosticsHint = "bugReport.openDiagnostics.accessibilityHint"
    case practiceFieldHint = "practiceField.field.accessibilityHint"
    case guidedOfferHint = "misbehaves.guided.accessibilityHint"
    case confirmFieldHint = "misbehaves.confirm.accessibilityHint"
    case answerYesHint = "misbehaves.ask.yes.accessibilityHint"
    case answerNoHint = "misbehaves.ask.no.accessibilityHint"
    case stopTestHint = "misbehaves.stop.accessibilityHint"
    case includePageAddressHint = "misbehaves.pageAddress.include.accessibilityHint"
    case pageAddressFieldHint = "misbehaves.pageAddress.field.accessibilityHint"
    case useForMeHint = "misbehaves.useForMe.accessibilityHint"
    case copySuggestionHint = "misbehaves.copySuggestion.accessibilityHint"
    case openGitHubIssueHint = "misbehaves.openGitHubIssue.accessibilityHint"
    case traceDurationHint = "trace.duration.accessibilityHint"
    case traceStartHint = "trace.confirm.start.accessibilityHint"
    case traceTextHint = "trace.review.text.accessibilityHint"
    case traceExportHint = "trace.review.export.accessibilityHint"
    case traceDiscardHint = "trace.review.discard.accessibilityHint"
    case probeStartHint = "probe.start.accessibilityHint"
    case probeFieldHint = "probe.field.accessibilityHint"
}

/// Every control of the Diagnostics windows with its VoiceOver label and hint keys (PRD-R66, PRD-R67).
public enum DiagnosticsControl: String, Sendable, CaseIterable {
    case copyReport, misbehaves, recordTrace, latencyTest, openLogs, reportText, appPicker, symptom, description,
        previewDisclosure, practiceButton, practiceAnswer, github, email, saveFile, openDiagnostics, practiceField,
        guidedOffer, confirmField, answerYes, answerNo, stopTest, includePageAddress, pageAddressField, useForMe,
        copySuggestion, openGitHubIssue, traceDuration, traceStart, traceText, traceExport, traceDiscard, probeStart,
        probeField

    /// The visible title doubles as the label, so VoiceOver reads what sighted users see.
    public var labelKey: DiagnosticsText {
        switch self {
        case .copyReport: .copyReport
        case .misbehaves: .misbehaves
        case .recordTrace: .recordTrace
        case .latencyTest: .latencyTest
        case .openLogs: .openLogs
        case .reportText: .reportHeading
        case .appPicker: .appLabel
        case .symptom: .symptomLabel
        case .description: .descriptionLabel
        case .previewDisclosure: .previewDisclosure
        case .practiceButton: .practiceButton
        case .practiceAnswer: .practiceLabel
        case .github: .github
        case .email: .email
        case .saveFile: .saveFile
        case .openDiagnostics: .openDiagnostics
        case .practiceField: .practiceTitle
        case .guidedOffer: .guidedOffer
        case .confirmField: .confirmButton
        case .answerYes: .answerYes
        case .answerNo: .answerNo
        case .stopTest: .stopTest
        case .includePageAddress: .includePageAddress
        case .pageAddressField: .pageAddressField
        case .useForMe: .useForMe
        case .copySuggestion: .copySuggestion
        case .openGitHubIssue: .openGitHubIssue
        case .traceDuration: .traceDuration
        case .traceStart: .traceStart
        case .traceText: .traceReviewTitle
        case .traceExport: .traceExport
        case .traceDiscard: .traceDiscard
        case .probeStart: .probeStart
        case .probeField: .probeField
        }
    }

    public var hintKey: DiagnosticsText {
        switch self {
        case .copyReport: .copyReportHint
        case .misbehaves: .misbehavesHint
        case .recordTrace: .recordTraceHint
        case .latencyTest: .latencyTestHint
        case .openLogs: .openLogsHint
        case .reportText: .reportTextHint
        case .appPicker: .appPickerHint
        case .symptom: .symptomHint
        case .description: .descriptionHint
        case .previewDisclosure: .previewDisclosureHint
        case .practiceButton: .practiceButtonHint
        case .practiceAnswer: .practiceAnswerHint
        case .github: .githubHint
        case .email: .emailHint
        case .saveFile: .saveFileHint
        case .openDiagnostics: .openDiagnosticsHint
        case .practiceField: .practiceFieldHint
        case .guidedOffer: .guidedOfferHint
        case .confirmField: .confirmFieldHint
        case .answerYes: .answerYesHint
        case .answerNo: .answerNoHint
        case .stopTest: .stopTestHint
        case .includePageAddress: .includePageAddressHint
        case .pageAddressField: .pageAddressFieldHint
        case .useForMe: .useForMeHint
        case .copySuggestion: .copySuggestionHint
        case .openGitHubIssue: .openGitHubIssueHint
        case .traceDuration: .traceDurationHint
        case .traceStart: .traceStartHint
        case .traceText: .traceTextHint
        case .traceExport: .traceExportHint
        case .traceDiscard: .traceDiscardHint
        case .probeStart: .probeStartHint
        case .probeField: .probeFieldHint
        }
    }
}

/// Composes Diagnostics copy from typed values, so every sentence comes from the catalog and the app name is
/// always an argument (PRD-R62).
public enum DiagnosticsCopy {
    /// PRD-R47 chips (six) and the PLT-R1205 symptom list (seven), in the spec's order.
    public static let sheetSymptoms: [DiagnosticsReport.Symptom] = [
        .lostLetters, .duplicatedLetters, .wrongTone, .cannotTypeVietnamese, .lag, .other,
    ]
    public static let misbehavesSymptoms: [DiagnosticsReport.Symptom] = [
        .duplicatedLetters, .lostLetters, .lettersOutOfOrder, .wrongTone, .nothingTyped, .lag, .other,
    ]

    /// Chip label (the shared `bugReport.symptom.*` copy of the common table).
    public static func symptom(_ symptom: DiagnosticsReport.Symptom, _ localizer: Localizer) -> String {
        localizer.string(BugReportSummary.symptomKey(symptom))
    }

    /// PLT-R1201 "health state with a plain explanation".
    public static func stateKey(_ state: HostStateCode) -> DiagnosticsText {
        switch state {
        case .readyVietnamese: .stateReadyVietnamese
        case .readyEnglish: .stateReadyEnglish
        case .starting: .stateStarting
        case .noPermission: .stateNoPermission
        case .paused(let code): pausedKey(code)
        case .failOpen(let reason): failOpenKey(reason)
        }
    }

    private static func pausedKey(_ code: PauseCode) -> DiagnosticsText {
        switch code {
        case .secureInput: .statePausedSecureInput
        case .nonLatinInputSource: .statePausedNonLatin
        case .builtInVietnameseSource: .statePausedBuiltIn
        case .passThroughRule: .statePausedRule
        case .secureField: .statePausedSecureField
        case .sessionInactive: .statePausedSession
        case .userDisabled: .statePausedUser
        case .noTextFocus: .statePausedNoText
        case .diagnosticsTest: .statePausedDiagnosticsTest
        }
    }

    private static func failOpenKey(_ reason: FailOpenReason) -> DiagnosticsText {
        switch reason {
        case .permissionRevoked: .stateFailPermission
        case .postingBroken: .stateFailPosting
        case .tapUnavailable: .stateFailTap
        case .watchdog: .stateFailWatchdog
        case .callbackStuck: .stateFailStuck
        }
    }

    public static func stateLine(_ state: HostStateCode, _ localizer: Localizer) -> String {
        localizer.format(DiagnosticsText.stateLabel, localizer.string(stateKey(state)))
    }

    public static func strategyKey(_ strategy: InjectionStrategy) -> DiagnosticsText {
        switch strategy {
        case .backspaceReplace: .strategyBackspaceReplace
        case .selectReplace: .strategySelectReplace
        case .axReplace: .strategyAXReplace
        case .paste: .strategyPaste
        case .passThrough: .strategyPassThrough
        }
    }

    /// "Backspace and retype, remove the suggestion first, 2 ms apart".
    public static func method(
        _ strategy: InjectionStrategy, inlineCompletion: InlineCompletionMode, interEventDelayUs: Int,
        _ localizer: Localizer
    ) -> String {
        var text = localizer.string(strategyKey(strategy))
        let handling: DiagnosticsText? =
            switch inlineCompletion {
            case .none: nil
            case .axSelection: .handlingAXSelection
            case .placeholder: .handlingPlaceholder
            case .axSelectionThenPlaceholder: .handlingBoth
            }
        if let handling { text = localizer.format(DiagnosticsText.candidateHandling, text, localizer.string(handling)) }
        if interEventDelayUs > 0 {
            text = localizer.format(DiagnosticsText.candidatePacing, text, interEventDelayUs / 1_000)
        }
        return text
    }

    public static func profileKey(_ profile: LatencyProbeResult.Profile) -> DiagnosticsText {
        switch profile {
        case .normal: .probeNormal
        case .fast: .probeFast
        case .burst: .probeBurst
        }
    }

    /// One line per profile: T2 and T4 percentiles in microseconds (02-platform.md 8.1).
    public static func probeLine(_ result: LatencyProbeResult.ProfileResult, _ localizer: Localizer) -> String {
        localizer.format(
            DiagnosticsText.probeResult, localizer.string(profileKey(result.profile)),
            Int(clamping: result.decideToPostedP50Microseconds), Int(clamping: result.decideToPostedP99Microseconds),
            Int(clamping: result.endToEndDeltaP50Microseconds), Int(clamping: result.endToEndDeltaP99Microseconds),
            result.samples)
    }
}
