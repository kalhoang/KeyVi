// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R47-R49: GitHub issue-form URL from Brand.repositoryURL, mail draft to Brand.supportEmail, mailto
// fallback; neither carries diagnostics beyond the summary; paths without a repository or address are hidden.

import AppModel
import Diagnostics
import Foundation
import Testing

@testable import ShellCore

@Suite struct BugReportComposerTests {
    let repository = URL(string: "https://github.com/example/repo")!

    func brand(email: String? = "support@example.invalid", repository: URL? = nil) -> Brand {
        Brand(
            displayName: "Example", slug: "example", siteHost: "example.invalid",
            bundleIdentifier: "invalid.example.app",
            version: "0.1.0", build: "7", supportEmail: email, repositoryURL: repository)
    }

    func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// Strings that exist only in the diagnostics block, never in the summary.
    let blockOnly = ["composer", "electron.default", "com.apple.keylayout.ABC", "Mac15,3", "AXTextArea", "OtherIME"]

    @Test func pathsDependOnTheBrand() {
        #expect(BugReportComposer.availablePaths(brand: brand(email: nil)) == [.saveFile])
        #expect(BugReportComposer.availablePaths(brand: brand()) == [.email, .saveFile])
        #expect(
            BugReportComposer.availablePaths(brand: brand(email: nil, repository: repository)) == [.github, .saveFile])
    }

    @Test func githubURLPrefillsTheIssueFormSummaryOnly() throws {
        let report = ReportFixtures.report()
        let url = BugReportComposer.githubIssueURL(repository: repository, draft: ReportFixtures.draft, report: report)
        #expect(url.absoluteString.hasPrefix("https://github.com/example/repo/issues/new?"))
        let items = queryItems(url)
        #expect(items["template"] == "bug.yml")
        #expect(items["title"] == "[Bug] Chat 2.3.1")
        #expect(items["app"] == "Chat 2.3.1")
        #expect(items["what-happened"] == ReportFixtures.draft.userDescription)  // typed by the user on purpose
        #expect(items["symptom"] == "Duplicated letters (Lặp chữ)")
        #expect(items["practice-field"] == "No, only in the app above (Không, chỉ ở ứng dụng trên)")
        #expect(items["diagnostics"] == nil)  // pasted by the user (PRD-R48)
        for marker in blockOnly { #expect(!url.absoluteString.contains(marker), "URL leaks \(marker)") }
        let trailing = BugReportComposer.githubIssueURL(
            repository: URL(string: "https://github.com/example/repo/")!, draft: ReportFixtures.draft, report: report)
        #expect(trailing.absoluteString.hasPrefix("https://github.com/example/repo/issues/new?"))
    }

    @Test func formOptionsMatchTheIssueTemplate() throws {
        // QA-R43: the form's own field IDs and option labels.
        let form = try String(contentsOf: RepoPaths.url(".github/ISSUE_TEMPLATE/bug.yml"), encoding: .utf8)
        for field in IssueFormURL.Field.allCases { #expect(form.contains("id: \(field.rawValue)\n")) }
        for symptom in DiagnosticsReport.Symptom.allCases {
            #expect(form.contains("- \(IssueFormURL.symptomOption(symptom))\n"), "\(symptom)")
        }
        for answer: Bool? in [true, false, nil] {
            #expect(form.contains("- \"\(IssueFormURL.practiceFieldOption(answer))\""))
        }
    }

    @Test func longDescriptionsAreCutAndSpecialCharactersSurvive() {
        let draft = BugReportDraft(
            app: nil, appName: nil, symptom: .other,
            userDescription: "a+b&c=d\n" + String(repeating: "x", count: 5_000), reproducesInPracticeField: nil)
        let url = BugReportComposer.githubIssueURL(
            repository: repository, draft: draft, report: ReportFixtures.report())
        let items = queryItems(url)
        #expect(items["what-happened"]?.hasPrefix("a+b&c=d\n") == true)
        #expect(items["what-happened"]?.count == IssueFormURL.descriptionLimit)
        #expect(items["title"] == "[Bug] ")
        #expect(items["practice-field"] == "I could not try (Chưa thử được)")
        #expect(url.absoluteString.utf8.count < 8_000)
    }

    @Test func mailDraftGoesToTheSupportAddressWithTheJSONAttachment() throws {
        let bundle = try TemporaryAppBundle(catalogs: [.common, .menu])
        let vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        let report = ReportFixtures.report()
        let mail = try #require(
            BugReportComposer.mail(draft: ReportFixtures.draft, report: report, brand: brand(), localizer: vi))
        #expect(mail.recipients == ["support@example.invalid"])
        #expect(mail.subject == "Example: báo lỗi với Chat 2.3.1")
        #expect(mail.attachmentFileName.hasPrefix("example-report-"))
        #expect(mail.attachmentFileName.hasSuffix(".json"))
        #expect(mail.body.contains(ReportFixtures.draft.userDescription))
        #expect(mail.body.contains("Chuyện gì xảy ra: Lặp chữ"))
        #expect(mail.body.contains("Phiên bản Example: 0.1.0 (7, beta)"))
        #expect(mail.body.contains("macOS: 27.1 (27B42), arm64"))
        #expect(mail.body.contains("Kiểu gõ: VNI"))
        #expect(mail.body.contains("Ô gõ thử: Không bị lỗi"))
        #expect(mail.body.contains(mail.attachmentFileName))
        for marker in blockOnly { #expect(!mail.body.contains(marker), "mail leaks \(marker)") }
        #expect(!mail.body.contains("%"))
    }

    @Test func mailWithoutAddressIsUnavailable() throws {
        let bundle = try TemporaryAppBundle(catalogs: [.common])
        let vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        #expect(
            BugReportComposer.mail(
                draft: ReportFixtures.draft, report: ReportFixtures.report(), brand: brand(email: nil), localizer: vi)
                == nil)
    }

    @Test func mailWithoutAppOrDescription() throws {
        let bundle = try TemporaryAppBundle(catalogs: [.common, .menu])
        let en = Localizer(language: .english, appBundle: bundle.bundle)
        let draft = BugReportDraft(
            app: nil, appName: nil, symptom: .nothingTyped, userDescription: "  ", reproducesInPracticeField: true)
        let mail = try #require(
            BugReportComposer.mail(
                draft: draft, report: ReportFixtures.report(draft: draft), brand: brand(), localizer: en))
        #expect(mail.subject == "Example: problem report")
        #expect(mail.body.contains("(No description)"))
        #expect(mail.body.contains("Practice field: Also happens there"))
        #expect(!mail.body.contains("App with the problem"))
        #expect(mail.body.contains("What happened: Nothing is typed"))
    }

    @Test func mailtoFallbackHasSubjectAndBodyWithCRLF() throws {
        let draft = MailDraft(
            recipients: ["a@example.invalid", "b@example.invalid"], subject: "Lỗi & hỏi?", body: "dòng 1\ndòng 2",
            attachmentFileName: "x.json")
        let url = try #require(BugReportComposer.mailtoURL(draft))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:a@example.invalid,b@example.invalid?subject="))
        #expect(url.absoluteString.contains("%0D%0A"))
        #expect(!url.absoluteString.contains("x.json"))
        let empty = MailDraft(recipients: [], subject: "s", body: "b", attachmentFileName: "x.json")
        #expect(BugReportComposer.mailtoURL(empty) == nil)
    }

    @Test func attachmentNameUsesLocalTime() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let name = BugReportComposer.attachmentFileName(slug: "example", date: ReportFixtures.now, timeZone: zone)
        #expect(name == "example-report-20261113-0700.json")
    }

    @Test func everySymptomHasAMailLabel() throws {
        let bundle = try TemporaryAppBundle(catalogs: [.common])
        let vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        let labels = DiagnosticsReport.Symptom.allCases.map { vi.string(BugReportSummary.symptomKey($0)) }
        #expect(Set(labels).count == labels.count)
        #expect(labels.contains("Chậm / giật"))
    }
}

@Suite struct SystemInfoReaderTests {
    @Test func readsTheRunningSystem() {
        let info = SystemInfoReader.current(uiLanguage: .english)
        #expect(info.uiLanguage == .english)
        #expect(LooseVersion(info.macOSVersion) != nil)
        #expect(!info.macOSBuild.isEmpty && info.macOSBuild != "unknown")
        #expect(["arm64", "x86_64"].contains(info.architecture))
        #expect(!info.modelIdentifier.isEmpty)
        #expect(!info.systemLanguage.isEmpty)
    }

    @Test func versionStringOmitsZeroPatch() {
        #expect(
            SystemInfoReader.versionString(OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0))
                == "27.1")
        #expect(
            SystemInfoReader.versionString(OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 2))
                == "15.7.2")
        #expect(SystemInfoReader.sysctlString("no.such.sysctl") == nil)
        #expect(SystemInfoReader.sysctlInt("no.such.sysctl") == nil)
    }
}
