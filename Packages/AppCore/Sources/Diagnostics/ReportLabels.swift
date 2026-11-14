// SPDX-License-Identifier: GPL-3.0-or-later
//
// Labels of the plain-text report (PLT-R1204) in the two interface languages (PRD-R63). Diagnostics has no
// resource bundle, so the strings live here; the app name is never part of them (brand rule). Vietnamese copy
// is standard and neutral (PRD-R62); the symptom names follow the PRD-R47 chips.

internal import AppModel

struct ReportLabels: Sendable {
    var title: String
    var generatedAt: String
    var yes: String
    var no: String
    var none: String
    var unknown: String
    var app: String
    var version: String
    var build: String
    var channel: String
    var system: String
    var architecture: String
    var model: String
    var systemLanguage: String
    var state: String
    var keyboard: String
    var layout: String
    var sourceKind: String
    var enabledSources: String
    var permissions: String
    var accessibility: String
    var postEvent: String
    var inputMonitoring: String
    var health: String
    var tap: String
    var enabled: String
    var location: String
    var timeouts: String
    var userInputDisables: String
    var lastReenable: String
    var secureInput: String
    var likelyHolder: String
    var holderKind: String
    var focus: String
    var engine: String
    var axData: String
    var role: String
    var subrole: String
    var identifier: String
    var domClasses: String
    var editable: String
    var secureField: String
    var appSource: String
    var rule: String
    var ruleID: String
    var source: String
    var specificity: String
    var strategy: String
    var parameters: String
    var isUserOverride: String
    var userOverride: String
    var omittedFields: String
    var settings: String
    var typingMethod: String
    var tonePlacement: String
    var englishRestore: String
    var standaloneW: String
    var bracketKeys: String
    var macros: String
    var macroCount: String
    var macrosInEnglish: String
    var rememberPerApp: String
    var toggleHotkey: String
    var restoreHotkey: String
    var interfaceLanguage: String
    var changedSettings: String
    var appMode: String
    var perAppRule: String
    var rememberedMode: String
    var latency: String
    var samples: String
    var counters: String
    var latencyTest: String
    var events: String
    var conflicts: String
    var userReport: String
    var symptom: String
    var reportedApp: String
    var practiceField: String
    var symptoms: [DiagnosticsReport.Symptom: String]

    static func labels(for language: InterfaceLanguage) -> ReportLabels {
        language == .vietnamese ? vietnamese : english
    }
}
