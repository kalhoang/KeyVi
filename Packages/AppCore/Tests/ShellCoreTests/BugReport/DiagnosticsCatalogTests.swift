// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The `Diagnostics` String Catalog (PRD-R62, PRD-R66, ADR 0310): every key in vi and en with matching format
// arguments, no brand literal, no dashes, no dead copy, a label and a hint for every control, PRD-R47 copy
// verbatim, and the copy helpers that compose sentences from typed values.

import AppModel
import Diagnostics
import Foundation
import Testing

@testable import ShellCore

@Suite struct DiagnosticsCatalogTests {
    static let referenced = Set(DiagnosticsText.allCases.map(\.rawValue))

    @Test func everyKeyHasViAndEnWithMatchingArguments() throws {
        let catalog = try Catalog(table: .diagnostics)
        #expect(catalog.sourceLanguage == "vi")
        for (key, entry) in catalog.entries {
            let vi = try #require(entry.values["vi"], "\(key) has no vi value")
            let en = try #require(entry.values["en"], "\(key) has no en value")
            #expect(!vi.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty vi")
            #expect(!en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty en")
            #expect(FormatSpecifiers.of(vi) == FormatSpecifiers.of(en), "\(key) arguments differ")
        }
    }

    @Test func noBrandLiteralsNoDashesNoSudo() throws {
        let catalog = try Catalog(table: .diagnostics)
        let brand = try BrandFiles.values()
        for (key, entry) in catalog.entries {
            for value in entry.values.values {
                for literal in [brand.displayName, brand.siteHost, brand.bundleID] {
                    #expect(!value.contains(literal), "\(key) hard-codes \(literal)")
                }
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"), "\(key) contains a dash")
                #expect(!value.lowercased().contains("sudo"), "\(key) suggests sudo")
            }
        }
    }

    @Test func everyReferencedKeyExistsAndNoCopyIsDead() throws {
        let present = Set(try Catalog(table: .diagnostics).entries.keys)
        #expect(Self.referenced.subtracting(present).sorted() == [], "missing in Diagnostics")
        #expect(present.subtracting(Self.referenced).sorted() == [], "unused in Diagnostics")
    }

    @Test func everyControlHasALabelAndAHintInTheOwnedCatalog() throws {
        // PRD-R66, workstream rule 8.
        let catalog = try Catalog(table: .diagnostics)
        for control in DiagnosticsControl.allCases {
            #expect(catalog.entries[control.labelKey.rawValue] != nil, "\(control) label")
            #expect(catalog.entries[control.hintKey.rawValue] != nil, "\(control) hint")
            #expect(control.labelKey != control.hintKey)
        }
        let hints = DiagnosticsControl.allCases.map(\.hintKey)
        #expect(Set(hints).count == hints.count, "each control has its own hint")
    }

    @Test func bugReportCopyIsVerbatimFromPRDR47() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let expected: [(DiagnosticsText, String)] = [
            (.appLabel, "Lỗi xảy ra ở ứng dụng nào?"), (.symptomLabel, "Chuyện gì xảy ra?"),
            (.descriptionLabel, "Bạn gõ gì và mong ra gì?"), (.previewDisclosure, "Xem trước dữ liệu sẽ gửi"),
            (.github, "Mở GitHub"), (.email, "Gửi qua email"), (.saveFile, "Lưu tệp..."),
            (.practiceButton, "Thử trong ô gõ thử"),
        ]
        for (key, text) in expected { #expect(vi.string(key) == text) }
        #expect(
            vi.format(DiagnosticsText.descriptionNote, "Bộ gõ")
                == "Bạn tự gõ lại ví dụ ở đây. Bộ gõ không tự gửi những gì bạn đã gõ.")
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(en.string(DiagnosticsText.copyReport) == "Copy report")
        #expect(en.string(DiagnosticsText.misbehaves) == "This app misbehaves...")
        #expect(en.string(DiagnosticsText.recordTrace) == "Record typing trace...")
        #expect(en.string(DiagnosticsText.latencyTest) == "Run typing latency test")
        #expect(en.string(DiagnosticsText.openLogs) == "Open logs folder")
    }
}

@Suite struct DiagnosticsCopyTests {
    static let states: [HostStateCode] =
        [.noPermission, .starting, .readyVietnamese, .readyEnglish]
        + [PauseCode.secureInput, .nonLatinInputSource, .builtInVietnameseSource, .passThroughRule, .secureField]
        .map(HostStateCode.paused)
        + [PauseCode.sessionInactive, .userDisabled, .noTextFocus].map(HostStateCode.paused)
        + [FailOpenReason.permissionRevoked, .postingBroken, .tapUnavailable, .watchdog, .callbackStuck]
        .map(HostStateCode.failOpen)

    @Test func everyHostStateHasItsOwnPlainExplanation() throws {
        let keys = Self.states.map(DiagnosticsCopy.stateKey)
        #expect(Set(keys).count == Self.states.count)
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(DiagnosticsCopy.stateLine(.readyVietnamese, en) == "State: Working normally, typing Vietnamese.")
    }

    @Test func methodsDescribeStrategyHandlingAndPacing() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(
            DiagnosticsCopy.method(.backspaceReplace, inlineCompletion: .none, interEventDelayUs: 0, en)
                == "Backspace and retype")
        #expect(
            DiagnosticsCopy.method(.backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 2_000, en)
                == "Backspace and retype, remove the suggestion first, 2 ms apart")
        let names = InjectionStrategy.allCases.map {
            DiagnosticsCopy.method($0, inlineCompletion: .none, interEventDelayUs: 0, en)
        }
        #expect(Set(names).count == InjectionStrategy.allCases.count)
        let handlings = [InlineCompletionMode.placeholder, .axSelectionThenPlaceholder].map {
            DiagnosticsCopy.method(.selectReplace, inlineCompletion: $0, interEventDelayUs: 0, en)
        }
        #expect(
            handlings == [
                "Select and replace, use a placeholder character",
                "Select and replace, remove the suggestion or use a placeholder",
            ])
    }

    @Test func probeLinesShowT2AndT4() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        let result = LatencyProbeResult.ProfileResult(
            profile: .burst, decideToPostedP50Microseconds: 400, decideToPostedP99Microseconds: 1_900,
            endToEndDeltaP50Microseconds: 1_200, endToEndDeltaP99Microseconds: 5_500, samples: 12)
        #expect(
            DiagnosticsCopy.probeLine(result, en)
                == "burst speed: send p50 400 µs, p99 1,900 µs; display delta p50 1,200 µs, p99 5,500 µs (12 samples)")
        // PRD-R65: numbers follow the interface language.
        let profiles = LatencyProbeResult.Profile.allCases.map(DiagnosticsCopy.profileKey)
        #expect(Set(profiles).count == 3)
    }

    @Test func symptomListsFollowTheSpec() throws {
        #expect(DiagnosticsCopy.sheetSymptoms.count == 6)  // PRD-R47 chips
        #expect(DiagnosticsCopy.misbehavesSymptoms.count == 7)  // PLT-R1205 step 2
        let app = try TemporaryAppBundle(catalogs: [.common])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(DiagnosticsCopy.symptom(.lostLetters, vi) == "Mất chữ")
    }
}
