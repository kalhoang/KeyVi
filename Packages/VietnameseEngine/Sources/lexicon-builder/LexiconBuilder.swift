// SPDX-License-Identifier: MPL-2.0
//
// lexicon-builder: builds the bundled word lists of VietnameseEngineData from pinned inputs
// (spec/01-engine.md 8.2, ENG-R810, ENG-R820). Every command is documented in data/README.md.

import Foundation

@main
struct LexiconBuilder {
    static let usage = """
        usage: lexicon-builder <command> [options]

        commands:
          build                 pinned inputs -> resource files and data/derived/
          check                 rebuild in a temporary directory; fail if any committed output differs (CI)
          prose-corpus          write data/corpus/prose-vi.txt (ENG-T20)
          ambiguity-candidates  list words whose Telex display is an attested Tier A syllable (ENG-R820)
          pin                   rewrite data/inputs/MANIFEST.sha256 from the files on disk
          import scowl|legal    turn verified downloads in data/cache/ into pinned inputs (macOS)
          tokenize [--prose]    print the tokens of standard input, one per line

        options:
          --data-root DIR       the repository's data/ directory (default: found from the working directory)
          --resources DIR       resource directory (default: <repo>/\(Layout.defaultResourcesPath))
          --output PATH         build/check: directory for Resources/ and derived/; prose-corpus and
                                ambiguity-candidates: output file ('-' for standard output)
          --min-tokens N        prose-corpus: minimum number of tokens (default \(ProseCorpus.defaultMinimumTokens))
          --fake-engine FILE    ambiguity-candidates: use a TSV table instead of the engine (tests)
          --merge               ambiguity-candidates: append missing candidates to inputs/ambiguity.tsv as unreviewed
        """

    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as BuilderError {
            FileHandle.standardError.write(Data("lexicon-builder: \(error.description)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("lexicon-builder: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) throws {
        var options = try Options(arguments)
        guard let command = options.positional.first else {
            print(usage)
            throw BuilderError("missing command")
        }
        options.positional.removeFirst()
        if command == "tokenize" { return try tokenize(prose: options.flags.contains("--prose")) }
        if command == "help" || command == "--help" { return print(usage) }
        let layout = try options.layout()
        switch command {
        case "build": try build(layout, options: options)
        case "check": try check(layout)
        case "prose-corpus": try proseCorpus(layout, options: options)
        case "ambiguity-candidates": try ambiguityCandidates(layout, options: options)
        case "pin": try pin(layout)
        case "import": try importInputs(layout, what: options.positional.first)
        default: throw BuilderError("unknown command '\(command)'\n\(usage)")
        }
    }

    static func build(_ layout: Layout, options: Options) throws {
        let output = try Builder.build(layout)
        if let directory = options.values["--output"] {
            let root = URL(fileURLWithPath: directory)
            try Builder.write(
                output, resources: root.appendingPathComponent("Resources"),
                derived: root.appendingPathComponent("derived"))
        } else {
            try Builder.write(output, resources: layout.resources, derived: layout.derived)
        }
        for file in output.resources { print("wrote \(file.name) (\(file.data.count) bytes)") }
    }

    /// CI gate (ENG-R810): inputs match their pins and every committed output is byte-identical to a
    /// fresh build.
    static func check(_ layout: Layout) throws {
        let output = try Builder.build(layout)
        let corpus = Data(try ProseCorpus.generate(layout, minimumTokens: ProseCorpus.defaultMinimumTokens).utf8)
        var expected: [(URL, Data)] = output.resources.map {
            (layout.resources.appendingPathComponent($0.name), $0.data)
        }
        expected += output.derived.map { (layout.derived.appendingPathComponent($0.name), $0.data) }
        expected.append((layout.corpusFile, corpus))
        var stale: [String] = []
        for (url, data) in expected where (try? Data(contentsOf: url)) != data {
            stale.append(url.path)
        }
        guard stale.isEmpty else {
            throw BuilderError(
                "committed outputs differ from a fresh build (run `lexicon-builder build` and `prose-corpus`):\n  "
                    + stale.joined(separator: "\n  "))
        }
        print("check passed: \(expected.count) outputs are reproducible from the pinned inputs")
    }

    static func proseCorpus(_ layout: Layout, options: Options) throws {
        let minimum = try options.integer("--min-tokens") ?? ProseCorpus.defaultMinimumTokens
        let text = try ProseCorpus.generate(layout, minimumTokens: minimum)
        try emit(text, to: options.values["--output"], default: layout.corpusFile)
    }

    static func ambiguityCandidates(_ layout: Layout, options: Options) throws {
        let candidates: [AmbiguityCandidate]
        if let fake = options.values["--fake-engine"] {
            candidates = try AmbiguityCandidates.generate(layout, typer: try TableTyper(URL(fileURLWithPath: fake)))
        } else {
            candidates = try AmbiguityCandidates.generate(layout, typer: EngineTyper())
        }
        try emit(
            AmbiguityCandidates.tsv(candidates), to: options.values["--output"],
            default: layout.derived.appendingPathComponent("ambiguity-candidates.tsv"))
        FileHandle.standardError.write(Data("\(candidates.count) candidates\n".utf8))
        if options.flags.contains("--merge") {
            let added = try AmbiguityCandidates.merge(
                candidates, into: layout.inputs.appendingPathComponent("ambiguity.tsv"))
            FileHandle.standardError.write(
                Data("added \(added) rows to inputs/ambiguity.tsv (see merge_as); run pin and build\n".utf8))
        }
    }

    static func pin(_ layout: Layout) throws {
        let manifest = try InputManifest.scan(layout)
        try FileIO.write(manifest.text, to: layout.manifestFile)
        print("pinned \(manifest.entries.count) input files in data/inputs/MANIFEST.sha256")
    }

    static func importInputs(_ layout: Layout, what: String?) throws {
        switch what {
        case "scowl": try Scowl.importArchive(layout)
        case "legal": try LegalTexts.importDocuments(layout)
        default: throw BuilderError("import needs 'scowl' or 'legal'")
        }
        try pin(layout)
    }

    static func tokenize(prose: Bool) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: input, encoding: .utf8) else { throw BuilderError("standard input is not UTF-8") }
        let tokens = prose ? VietnameseText.proseTokens(text) : VietnameseText.syllableTokens(text)
        FileHandle.standardOutput.write(Data(joinedLines(tokens).utf8))
    }

    private static func emit(_ text: String, to path: String?, default url: URL) throws {
        if path == "-" {
            FileHandle.standardOutput.write(Data(text.utf8))
        } else {
            let target = path.map { URL(fileURLWithPath: $0) } ?? url
            try FileIO.write(text, to: target)
            FileHandle.standardError.write(Data("wrote \(target.path)\n".utf8))
        }
    }
}

struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = ["--data-root", "--resources", "--output", "--min-tokens", "--fake-engine"]
    static let flagOptions: Set<String> = ["--merge", "--prose"]

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if Options.valueOptions.contains(argument) {
                guard let value = iterator.next() else { throw BuilderError("\(argument) needs a value") }
                values[argument] = value
            } else if Options.flagOptions.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--") {
                throw BuilderError("unknown option \(argument)")
            } else {
                positional.append(argument)
            }
        }
    }

    func integer(_ name: String) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let value = Int(text), value > 0 else { throw BuilderError("\(name) needs a positive integer") }
        return value
    }

    func layout() throws -> Layout {
        let dataRoot: URL
        if let path = values["--data-root"] {
            dataRoot = URL(fileURLWithPath: path)
        } else if let found = Layout.locateDataRoot(
            from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        {
            dataRoot = found
        } else {
            throw BuilderError("cannot find data/inputs/MANIFEST.sha256 above the working directory; pass --data-root")
        }
        let resources =
            values["--resources"].map { URL(fileURLWithPath: $0) }
            ?? dataRoot.deletingLastPathComponent().appendingPathComponent(Layout.defaultResourcesPath)
        return Layout(dataRoot: dataRoot, resources: resources)
    }
}
