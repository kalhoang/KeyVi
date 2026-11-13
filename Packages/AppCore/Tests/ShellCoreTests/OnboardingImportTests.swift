// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding screen 6 import (PRD-R40, PRD-R32, PRD-R43 "Import file invalid", PRD-R70): the chosen file gets the
// Macros pane's preview (counts of new, duplicate and invalid rows, the duplicate choice, invalid lines with
// their reason) before anything is merged; a refused or unreadable file is explained and the flow stays on the
// screen until the user confirms an import or leaves it for later.

import AppModel
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct OnboardingImportTests {
    let mine = [StoredMacro(trigger: "vn", expansion: "Việt Nam")]

    @Test func aValidFileIsPreviewedBeforeAnythingIsMerged_PRDR32() throws {
        let l = try Localizers()
        let data = Data("vn\tViet Nam\ndc\tđược\nbad key\tx\n".utf8)
        var step = OnboardingImport.opening(data, fileExtension: "txt", existing: mine, localizer: l.vi)
        let session = try #require(step.session)
        #expect(session.newCount == 1 && session.duplicateCount == 1 && session.invalidCount == 1)
        #expect(session.invalidLines(l.vi) == ["Dòng 3: phím tắt không được có khoảng trắng."])
        #expect(step.error == nil)
        #expect(!step.advancesFlow)  // nothing merged yet
        step.session?.resolution = .useImported
        let confirmed = step.confirm(existing: mine, localizer: l.vi)
        let merged = try #require(confirmed)
        #expect(merged.first { $0.trigger == "vn" }?.expansion == "Viet Nam")
        #expect(merged.count == 2)
        #expect(step.advancesFlow)
    }

    @Test func anInvalidFileIsExplainedAndTheFlowStays_PRDR43() throws {
        let l = try Localizers()
        var step = OnboardingImport.opening(
            Data("vn x\tViệt Nam\nok\t\n".utf8), fileExtension: "txt", existing: mine, localizer: l.vi)
        #expect(step.session == nil)
        #expect(step.error == "Tệp này không đúng định dạng. Dòng 1: phím tắt không được có khoảng trắng.")
        let confirmed = step.confirm(existing: mine, localizer: l.vi)
        #expect(confirmed == nil)
        #expect(!step.advancesFlow)
        let unreadable = OnboardingImport.opening(nil, fileExtension: "txt", existing: mine, localizer: l.en)
        #expect(unreadable.error == l.en.string(MacrosText.importUnreadable))
        #expect(!unreadable.advancesFlow)
        let big = OnboardingImport.opening(
            Data(count: MacroImporter.maxFileBytes + 1), fileExtension: "txt", existing: mine, localizer: l.vi)
        #expect(big.error == "Tệp này lớn hơn 5 MB.")
    }
}
