// SPDX-License-Identifier: LicenseRef-App-Pending
//
// JSON forms of the report (PRD-R47 attachment) and of the reported user override as rule JSON in the
// `compat/rules.json` 5.4 shape (PLT-R541, docs/decisions/0312-report-override-projection.md).

internal import AppModel
internal import Foundation

enum ReportJSON {
    static func encode(_ report: DiagnosticsReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One-line, key-sorted JSON of a typed value. Encoding the typed report values cannot fail; an empty
    /// object is returned if it ever did.
    static func compact(_ value: some Encodable) -> String {
        text(value, pretty: false)
    }

    static func rule(_ override: DiagnosticsReport.ReportedOverride, pretty: Bool) -> String {
        text(RuleDocument(override), pretty: pretty)
    }

    private static func text(_ value: some Encodable, pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `{"id", "match", "action"}` of a rule. `summary` and provenance are left for the maintainer to add.
private struct RuleDocument: Encodable {
    let id: RuleID
    let match: MatchDocument
    let action: ActionDocument

    init(_ override: DiagnosticsReport.ReportedOverride) {
        id = override.id
        match = MatchDocument(override.match)
        action = ActionDocument(
            strategy: override.strategy, params: override.parameters, fallback: override.fallback,
            requireTextFocus: override.requireTextFocus, verifyReentry: override.verifyReentry,
            engineContext: override.engineContext)
    }
}

private struct MatchDocument: Encodable {
    let bundleIds: [BundleKey]?
    let bundleGroup: String?
    let engines: [EngineFingerprint]?
    let appCategories: [String]?
    let appVersion: VersionRange?
    let macOS: VersionRange?
    let ax: AXDocument?

    init(_ match: DiagnosticsReport.ReportedMatch) {
        bundleIds = match.bundleIds
        bundleGroup = match.bundleGroup
        engines = match.engines
        appCategories = match.appCategories
        appVersion = match.appVersion
        macOS = match.macOS
        let ax = AXDocument(
            roles: match.axRoles, subroles: match.axSubroles, identifiers: match.axIdentifiers,
            domClasses: match.axDomClasses, ancestorRoles: match.axAncestorRoles, editable: match.axEditable)
        self.ax = ax.isEmpty ? nil : ax
    }
}

private struct AXDocument: Encodable {
    let roles: [String]?
    let subroles: [String]?
    let identifiers: [String]?
    let domClasses: [String]?
    let ancestorRoles: [String]?
    let editable: Bool?

    var isEmpty: Bool {
        roles == nil && subroles == nil && identifiers == nil && domClasses == nil && ancestorRoles == nil
            && editable == nil
    }
}

private struct ActionDocument: Encodable {
    let strategy: InjectionStrategy
    let params: DiagnosticsReport.ReportedParameters?
    let fallback: [InjectionStrategy]?
    let requireTextFocus: RequireTextFocus?
    let verifyReentry: VerifyReentry?
    let engineContext: EngineContextKind?
}
