// SPDX-License-Identifier: MPL-2.0
//
// `lexicon-builder import`: turns the raw downloads in data/cache/ (fetched and checksum-verified by
// data/fetch.sh) into the committed, pinned inputs under data/inputs/ and data/licenses/.
// The build itself never reads data/cache/, so CI can rebuild offline (ENG-R810).

import Foundation

enum Scowl {
    static let release = "scowl-2020.12.07"
    /// Component lists used for the English lexicon (spec/01-engine.md 8.2): the `words` category of the
    /// spelling-neutral, American and British (-ise and -ize) lists, size levels up to 35.
    /// Variant lists (`variant_1` ...), proper names, abbreviations, contractions and upper-case lists are
    /// excluded (docs/decisions/0200-data-sources-and-licences.md).
    static let categories = ["english", "american", "british", "british_z"]
    static let levels = [10, 20, 35]

    static var componentFiles: [String] {
        categories.flatMap { category in levels.map { "\(category)-words.\($0)" } }
    }

    static let licenseFile = "SCOWL-2020.12.07-Copyright.txt"
    static let readmeFile = "SCOWL-2020.12.07-README.txt"

    static func importArchive(_ layout: Layout) throws {
        let sources = try DownloadSource.load(layout.inputs.appendingPathComponent("english/SOURCES.tsv"))
        guard let source = sources.first(where: { $0.id == release }) else {
            throw BuilderError("inputs/english/SOURCES.tsv has no row for \(release)")
        }
        _ = try source.verifiedData(layout)
        let work = try FileIO.temporaryDirectory("scowl")
        defer { try? FileManager.default.removeItem(at: work) }
        let members = componentFiles.map { "\(release)/final/\($0)" } + ["\(release)/Copyright", "\(release)/README"]
        let archive = layout.cache.appendingPathComponent(source.file).path
        _ = try FileIO.run("/usr/bin/tar", ["-xzf", archive, "-C", work.path] + members)
        let extracted = work.appendingPathComponent(release)
        for file in componentFiles {
            try FileIO.write(
                try FileIO.read(extracted.appendingPathComponent("final/\(file)")),
                to: layout.scowlDirectory.appendingPathComponent(file))
        }
        try FileIO.write(
            try FileIO.read(extracted.appendingPathComponent("Copyright")),
            to: layout.licenses.appendingPathComponent(licenseFile))
        try FileIO.write(
            try FileIO.read(extracted.appendingPathComponent("README")),
            to: layout.licenses.appendingPathComponent(readmeFile))
    }
}

enum LegalTexts {
    static func sources(_ layout: Layout) throws -> [DownloadSource] {
        try DownloadSource.load(layout.legalDirectory.appendingPathComponent("SOURCES.tsv"))
    }

    static func textFile(_ layout: Layout, id: String) -> URL {
        layout.legalDirectory.appendingPathComponent("\(id).txt")
    }

    /// Converts every pinned legal document (Word .doc) to clean UTF-8 NFC text with macOS `textutil`.
    static func importDocuments(_ layout: Layout) throws {
        #if os(macOS)
        for source in try sources(layout) {
            _ = try source.verifiedData(layout)
            let raw = layout.cache.appendingPathComponent(source.file).path
            let output = try FileIO.run(
                "/usr/bin/textutil", ["-convert", "txt", "-encoding", "UTF-8", "-stdout", raw])
            try FileIO.write(clean(String(decoding: output, as: UTF8.self)), to: textFile(layout, id: source.id))
        }
        #else
        throw BuilderError("importing legal documents needs macOS textutil")
        #endif
    }

    /// Normalises extracted text: NFC, `Ð`/`ð` (Icelandic eth, a common typing slip in Vietnamese
    /// documents) to `Đ`/`đ`, all line separators to LF, no-break spaces to spaces, no trailing spaces,
    /// at most one blank line in a row.
    static func clean(_ text: String) -> String {
        var normalized = VietnameseText.nfc(text)
        let replacements: [(String, String)] = [
            ("\r\n", "\n"), ("\r", "\n"), ("\u{2028}", "\n"), ("\u{2029}", "\n"), ("\u{000B}", "\n"),
            ("\u{000C}", "\n"), ("\u{00A0}", " "), ("\u{00D0}", "Đ"), ("\u{00F0}", "đ"), ("\t", " "),
        ]
        for (from, to) in replacements { normalized = normalized.replacingOccurrences(of: from, with: to) }
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacingOccurrences(of: " +$", with: "", options: .regularExpression)
            let trimmedLeading = line.replacingOccurrences(of: "^ +", with: "", options: .regularExpression)
            if trimmedLeading.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmedLeading)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return joinedLines(lines)
    }
}
