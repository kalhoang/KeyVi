// SPDX-License-Identifier: MPL-2.0
//
// data/inputs/MANIFEST.sha256 pins every committed input of the build (ENG-R810).
// Format: `shasum -a 256` output, paths relative to `data/`, sorted by path, so that
// `cd data && shasum -a 256 -c inputs/MANIFEST.sha256` verifies the inputs without this tool.

import Foundation

struct InputManifest {
    struct Entry: Equatable {
        let sha256: String
        let path: String
    }

    let entries: [Entry]

    /// Directories (relative to `data/`) whose files are pinned.
    static let pinnedDirectories = ["inputs", "licenses"]

    static func load(_ layout: Layout) throws -> InputManifest {
        let text = try FileIO.readUTF8(layout.manifestFile)
        var entries: [Entry] = []
        for (number, line) in FileIO.contentLines(text) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64 else {
                throw BuilderError("MANIFEST.sha256 line \(number): expected '<sha256>  <path>'")
            }
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            entries.append(Entry(sha256: String(parts[0]), path: path))
        }
        return InputManifest(entries: entries)
    }

    /// Computes the manifest of the files currently on disk.
    static func scan(_ layout: Layout) throws -> InputManifest {
        var entries: [Entry] = []
        for directory in pinnedDirectories {
            for path in try files(under: layout.dataRoot.appendingPathComponent(directory), prefix: directory)
            where path != "inputs/MANIFEST.sha256" {
                let data = try FileIO.read(layout.dataRoot.appendingPathComponent(path))
                entries.append(Entry(sha256: SHA256.hex(of: data), path: path))
            }
        }
        return InputManifest(entries: entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
    }

    var text: String {
        let header = [
            "# SHA-256 of every pinned build input, relative to data/. Regenerate with `lexicon-builder pin`.",
            "# Verify without the tool: cd data && shasum -a 256 -c inputs/MANIFEST.sha256",
        ]
        return joinedLines(header + entries.map { "\($0.sha256)  \($0.path)" })
    }

    /// Fails unless the files on disk are exactly the pinned ones.
    static func verify(_ layout: Layout) throws {
        let pinned = try load(layout)
        let actual = try scan(layout)
        guard pinned.entries != actual.entries else { return }
        let pinnedByPath = Dictionary(uniqueKeysWithValues: pinned.entries.map { ($0.path, $0.sha256) })
        let actualByPath = Dictionary(uniqueKeysWithValues: actual.entries.map { ($0.path, $0.sha256) })
        var problems: [String] = []
        for (path, sha) in actualByPath.sorted(by: { $0.key < $1.key }) {
            if let expected = pinnedByPath[path] {
                if expected != sha { problems.append("changed: \(path)") }
            } else {
                problems.append("not pinned: \(path)")
            }
        }
        for path in pinnedByPath.keys.sorted() where actualByPath[path] == nil {
            problems.append("missing: \(path)")
        }
        throw BuilderError(
            "inputs do not match data/inputs/MANIFEST.sha256 (run `lexicon-builder pin` after a reviewed change):\n  "
                + problems.joined(separator: "\n  "))
    }

    private static func files(under root: URL, prefix: String) throws -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [String] = []
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = String(full.dropFirst(rootPath.count + 1))
            result.append("\(prefix)/\(relative)")
        }
        return result
    }
}

/// One downloadable source: a row of `inputs/english/SOURCES.tsv` or `inputs/legal/SOURCES.tsv`.
/// Columns: id, file (in data/cache/), url, sha256, bytes, retrieved, title, number, issued, issuer, page.
struct DownloadSource {
    let id: String
    let file: String
    let url: String
    let sha256: String
    let bytes: Int
    let retrieved: String
    let title: String
    let number: String
    let issued: String
    let issuer: String
    let page: String

    static let columns = [
        "id", "file", "url", "sha256", "bytes", "retrieved", "title", "number", "issued", "issuer", "page",
    ]

    static func load(_ url: URL) throws -> [DownloadSource] {
        let lines = try FileIO.readUTF8(url).split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("#") && !$0.isEmpty
        }
        guard let header = lines.first, header.split(separator: "\t").map(String.init) == columns else {
            throw BuilderError("\(url.path): header must be \(columns.joined(separator: "<TAB>"))")
        }
        return try lines.dropFirst().enumerated().map { index, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == columns.count, let bytes = Int(fields[4]), fields[3].count == 64 else {
                throw BuilderError("\(url.path) row \(index + 1): expected \(columns.count) tab-separated fields")
            }
            return DownloadSource(
                id: fields[0], file: fields[1], url: fields[2], sha256: fields[3], bytes: bytes,
                retrieved: fields[5], title: fields[6], number: fields[7], issued: fields[8],
                issuer: fields[9], page: fields[10])
        }
    }

    /// Reads the cached raw download and checks its pinned SHA-256.
    func verifiedData(_ layout: Layout) throws -> Data {
        let url = layout.cache.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BuilderError("missing download data/cache/\(file): run data/fetch.sh first")
        }
        let data = try FileIO.read(url)
        let digest = SHA256.hex(of: data)
        guard digest == sha256 else {
            throw BuilderError("data/cache/\(file): SHA-256 \(digest) does not match the pinned \(sha256)")
        }
        return data
    }
}
