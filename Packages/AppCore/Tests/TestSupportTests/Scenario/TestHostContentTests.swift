// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 and 13.2 content checks over TestHost/** (the app target has no unit-test target; these read its files):
// local pages load from file:// without network access, every page field is a TestHost field, the window
// builds every field kind with its accessibility identifier, and the harness constants match the app.

import Foundation
import Testing

@testable import TestSupport

private let pagesDirectory = repositoryRoot.appendingPathComponent("TestHost/Resources/Pages")
private let sourcesDirectory = repositoryRoot.appendingPathComponent("TestHost/Sources")

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func files(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func matches(_ pattern: String, in text: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
}

/// Raw values of `enum TestHostField` in TestHost/Sources/TestHostFields.swift.
private func testHostFieldIDs() throws -> [String] {
    matches(
        #"case \w+ = "(testhost\.[A-Za-z.]+)""#,
        in: try read(sourcesDirectory.appendingPathComponent("TestHostFields.swift")))
}

@Suite struct LocalPagesTests {
    /// 13.2 / W2-E1 acceptance: pages load from file:// without network access.
    @Test func pagesContainNoNetworkReferences() throws {
        let pages = try files(in: pagesDirectory)
        #expect(!pages.isEmpty)
        for page in pages {
            let text = try read(page)
            #expect(text.range(of: "http://", options: .caseInsensitive) == nil, "\(page.lastPathComponent)")
            #expect(text.range(of: "https://", options: .caseInsensitive) == nil, "\(page.lastPathComponent)")
            // Protocol-relative URLs ("//host/x") would fetch over the network as well.
            let references =
                matches(#"(?:src|href)\s*=\s*"([^"]*)""#, in: text) + matches(#"url\(\s*['"]?([^'")]*)"#, in: text)
            for reference in references {
                #expect(
                    !reference.hasPrefix("//") && !reference.contains(":"), "\(page.lastPathComponent): \(reference)")
                #expect(
                    FileManager.default.fileExists(atPath: pagesDirectory.appendingPathComponent(reference).path),
                    "\(page.lastPathComponent) references missing \(reference)")
            }
        }
    }

    @Test func theCheckRejectsNetworkReferences() {
        // Guard against a vacuous check: the same patterns find these.
        #expect(!matches(#"(?:src|href)\s*=\s*"([^"]*)""#, in: #"<script src="//cdn.example/x.js">"#).isEmpty)
        #expect("<img src=\"HTTPS://a\">".range(of: "https://", options: .caseInsensitive) != nil)
    }

    @Test func requiredPagesExist() throws {
        let names = Set(try files(in: pagesDirectory).map(\.lastPathComponent))
        for page in [
            "fields.html", "inline-autocomplete.html", "edit-mode-transition.html", "contenteditable-composer.html",
            "testhost.js", "testhost.css", "index.html",
        ] {
            #expect(names.contains(page), "\(page)")
        }
    }

    /// QA-R10: the web view page has an input, a textarea and a contenteditable element, each mirrored.
    @Test func fieldsPageHasTheThreeWebFields() throws {
        let text = try read(pagesDirectory.appendingPathComponent("fields.html"))
        #expect(text.contains(#"<input id="web-input""#))
        #expect(text.contains(#"<textarea id="web-textarea""#))
        #expect(text.contains(#"contenteditable="true""#))
        let fields = Set(matches(#"data-testhost-field="([^"]+)""#, in: text))
        #expect(fields == ["testhost.web.input", "testhost.web.textarea", "testhost.web.contentEditable"])
    }

    @Test func everyPageFieldIsATestHostField() throws {
        let known = Set(try testHostFieldIDs())
        for page in try files(in: pagesDirectory) where page.pathExtension == "html" {
            for field in matches(#"data-testhost-field="([^"]+)""#, in: try read(page)) {
                #expect(known.contains(field), "\(page.lastPathComponent): \(field)")
            }
        }
    }

    @Test func behaviourPagesCarryTheirMechanism() throws {
        let inline = try read(pagesDirectory.appendingPathComponent("inline-autocomplete.html"))
        #expect(inline.contains("data-testhost-completions="))
        let transition = try read(pagesDirectory.appendingPathComponent("edit-mode-transition.html"))
        #expect(transition.contains("transitionMilliseconds") && transition.contains("data-testhost-fold-diacritics"))
        let composer = try read(pagesDirectory.appendingPathComponent("contenteditable-composer.html"))
        #expect(composer.contains(#"contenteditable="true""#) && composer.contains("\"Enter\""))
        let script = try read(pagesDirectory.appendingPathComponent("testhost.js"))
        #expect(script.contains("messageHandlers") && script.contains("data-testhost-echo"))
    }

    @Test func scriptsAndStylesCarrySPDXHeaders() throws {
        for page in try files(in: pagesDirectory) where ["js", "css", "html"].contains(page.pathExtension) {
            let head = try read(page).split(separator: "\n").prefix(5).joined(separator: "\n")
            #expect(head.contains("SPDX-License-Identifier: LicenseRef-App-Pending"), "\(page.lastPathComponent)")
        }
    }
}

@Suite struct TestHostSourcesTests {
    /// QA-R10 field list, in the contract's order.
    @Test func everyFieldKindIsDeclared() throws {
        #expect(
            try testHostFieldIDs() == [
                "testhost.native.textField", "testhost.native.textView", "testhost.web.input", "testhost.web.textarea",
                "testhost.web.contentEditable", "testhost.sim.addressBar", "testhost.sim.sheetCell",
                "testhost.native.password",
            ])
    }

    @Test func windowBuildsAndExposesEveryField() throws {
        let controller = try read(sourcesDirectory.appendingPathComponent("TestHostFields.swift"))
        let web = try read(sourcesDirectory.appendingPathComponent("WebFields.swift"))
        for native in [
            "nativeTextField", "nativeTextView", "addressBarWithCompletion", "spreadsheetCell", "passwordField",
        ] {
            #expect(controller.contains("access[." + native + "]"), "\(native)")
        }
        #expect(controller.contains("for field in WebFieldsController.mirroredFields"))
        #expect(web.contains("[.webInput, .webTextarea, .webContentEditable]"))
        #expect(web.contains("mirror.setAccessibilityIdentifier(field.rawValue)"))
    }

    @Test func harnessConstantsMatchTheApp() throws {
        let sources = try files(in: sourcesDirectory).map(read).joined(separator: "\n")
        #expect(sources.contains("\"" + TestHostControls.secureInputToggle + "\""))
        #expect(try testHostFieldIDs().contains(TestHostControls.typingField))
    }

    @Test func pickerListsExactlyTheBundledPages() throws {
        let web = try read(sourcesDirectory.appendingPathComponent("WebFields.swift"))
        let listed = matches(#""([a-z-]+\.html)""#, in: web)
        let bundled = try files(in: pagesDirectory).map(\.lastPathComponent).filter {
            $0.hasSuffix(".html") && $0 != "index.html"
        }
        #expect(Set(listed) == Set(bundled))
    }

    /// Brand and network rules for the app sources: no bundle-ID literal, no remote URL, no print.
    @Test func sourcesStayBrandNeutralAndOffline() throws {
        for file in try files(in: sourcesDirectory) {
            let text = try read(file)
            #expect(
                matches(#""((?:com|org|net|io|dev|app|vn)\.[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+)""#, in: text).isEmpty,
                "\(file.lastPathComponent)")
            #expect(text.range(of: "http", options: .caseInsensitive) == nil, "\(file.lastPathComponent)")
            #expect(!text.contains("print("), "\(file.lastPathComponent)")
        }
    }

    @Test func pageHandlerNeverBecomesTheDefaultHTMLViewer() throws {
        let plist = try read(repositoryRoot.appendingPathComponent("TestHost/Info.plist"))
        #expect(plist.contains("<key>LSHandlerRank</key>\n\t\t\t<string>None</string>"))
    }
}
