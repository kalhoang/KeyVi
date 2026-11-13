// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The short summary that goes into the GitHub issue form and the mail body (PRD-R47). It holds the reported app,
// the symptom, the practice-field answer, app and macOS versions, architecture and typing method, plus the text
// the user wrote on purpose. Everything else stays in the diagnostics block (pasted by the user) or the attached
// JSON file, never in the URL or the body.

internal import AppModel
internal import Diagnostics
internal import Foundation

struct BugReportSummary {
    var draft: BugReportDraft
    var report: DiagnosticsReport

    /// "<name> <version>" of the reported app; the version only when the report's focus is that app.
    var reportedApp: String? {
        guard let name = draft.appName ?? draft.app?.rawValue else { return nil }
        guard let version = report.focus.flatMap({ $0.bundle == draft.app ? $0.appVersion : nil }) else { return name }
        return "\(name) \(version)"
    }

    func mailSubject(_ localizer: Localizer, appName: String) -> String {
        guard let reportedApp else { return localizer.format(CommonText.mailSubjectNoApp, appName) }
        return localizer.format(CommonText.mailSubject, appName, reportedApp)
    }

    func mailBody(_ localizer: Localizer, appName: String, attachment: String) -> String {
        let description = draft.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            localizer.string(CommonText.mailDescription),
            description.isEmpty ? localizer.string(CommonText.mailNoDescription) : description,
            "",
            localizer.string(CommonText.mailSummary),
        ]
        if let reportedApp { lines.append(localizer.format(CommonText.mailApp, reportedApp)) }
        lines += [
            localizer.format(CommonText.mailSymptom, localizer.string(Self.symptomKey(draft.symptom))),
            localizer.format(CommonText.mailPracticeField, localizer.string(practiceFieldKey)),
            localizer.format(
                CommonText.mailVersion, appName, report.app.version, report.app.build, report.app.channel.rawValue),
            localizer.format(
                CommonText.mailMacOS, report.system.macOSVersion, report.system.macOSBuild, report.system.architecture),
            localizer.format(CommonText.mailMethod, methodName(localizer)),
            "",
            localizer.format(CommonText.mailAttachment, attachment),
        ]
        return lines.joined(separator: "\n")
    }

    private var practiceFieldKey: CommonText {
        switch draft.reproducesInPracticeField {
        case true?: .mailPracticeFieldYes
        case false?: .mailPracticeFieldNo
        case nil: .mailPracticeFieldUnknown
        }
    }

    private func methodName(_ localizer: Localizer) -> String {
        localizer.string(report.settings.typingMethod == .telex ? MenuText.methodTelex : MenuText.methodVNI)
    }

    static func symptomKey(_ symptom: DiagnosticsReport.Symptom) -> CommonText {
        switch symptom {
        case .lostLetters: .symptomLostLetters
        case .duplicatedLetters: .symptomDuplicatedLetters
        case .lettersOutOfOrder: .symptomLettersOutOfOrder
        case .wrongTone: .symptomWrongTone
        case .cannotTypeVietnamese: .symptomCannotTypeVietnamese
        case .nothingTyped: .symptomNothingTyped
        case .lag: .symptomLag
        case .other: .symptomOther
        }
    }
}

/// Prefilled `.github/ISSUE_TEMPLATE/bug.yml` form (QA-R43). Field IDs and dropdown option labels are the
/// form's own values; a test reads bug.yml so they cannot drift. The diagnostics field is left for the user to
/// paste (PRD-R48), so the URL never contains the block.
enum IssueFormURL {
    static let template = "bug.yml"
    static let titlePrefix = "[Bug] "
    /// GitHub rejects very long URLs; the description is cut to keep the whole URL well under 8 KB.
    static let descriptionLimit = 2_000

    enum Field: String, CaseIterable {
        case app
        case whatHappened = "what-happened"
        case symptom
        case practiceField = "practice-field"
    }

    static func symptomOption(_ symptom: DiagnosticsReport.Symptom) -> String {
        switch symptom {
        case .lostLetters: "Lost letters (Mất chữ)"
        case .duplicatedLetters: "Duplicated letters (Lặp chữ)"
        case .wrongTone: "Wrong tone or mark (Sai dấu)"
        case .cannotTypeVietnamese: "Cannot type Vietnamese (Không gõ được tiếng Việt)"
        case .lag: "Lag or stutter (Chậm hoặc giật)"
        case .lettersOutOfOrder, .nothingTyped, .other: "Other (Khác)"
        }
    }

    static func practiceFieldOption(_ reproduces: Bool?) -> String {
        switch reproduces {
        case true?: "Yes, also in the practice field (Có, cả ở ô gõ thử)"
        case false?: "No, only in the app above (Không, chỉ ở ứng dụng trên)"
        case nil: "I could not try (Chưa thử được)"
        }
    }

    static func make(repository: URL, draft: BugReportDraft, report: DiagnosticsReport) -> URL {
        let summary = BugReportSummary(draft: draft, report: report)
        let app = summary.reportedApp ?? ""
        let items: [(String, String)] = [
            ("template", template),
            ("title", titlePrefix + app),
            (Field.app.rawValue, app),
            (Field.whatHappened.rawValue, String(draft.userDescription.prefix(descriptionLimit))),
            (Field.symptom.rawValue, symptomOption(draft.symptom)),
            (Field.practiceField.rawValue, practiceFieldOption(draft.reproducesInPracticeField)),
        ]
        let query = items.map { "\($0.0)=\(URLQueryEncoding.encode($0.1))" }.joined(separator: "&")
        let base =
            repository.absoluteString.hasSuffix("/")
            ? String(repository.absoluteString.dropLast())
            : repository.absoluteString
        // Every component is percent-encoded with the unreserved set, so the string is always a valid URL.
        return URL(string: "\(base)/issues/new?\(query)")!
    }
}

/// Strict percent-encoding (RFC 3986 unreserved characters only), so `+`, `&`, `=` and line breaks survive.
enum URLQueryEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `mailto:` addresses keep `@` readable (RFC 6068 addr-spec); everything else is encoded.
    static func encodeAddress(_ address: String) -> String {
        address.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "@"))) ?? ""
    }
}
