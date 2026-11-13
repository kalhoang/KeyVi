// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// PLT-R340: a focus change is a hard boundary, so the edit-mode cell must keep the keyboard focus from the
    /// first key on. The earlier page moved it from a grid cell to a hidden editor after the first key; with the
    /// host tracking that change, "D" + "d" could only give "Dd", and the scenario passed only when the host saw the
    /// change late (testhost.web.editModeTransition, integration-suite.md section 10.5).
    @Test func editModeCellKeepsTheFocusFromTheFirstKey() throws {
        let transition = try read(pagesDirectory.appendingPathComponent("edit-mode-transition.html"))
        #expect(matches(#"class="([^"]*\btesthost-edit-mode-cell\b[^"]*)""#, in: transition).count == 1)
        #expect(matches(#"data-testhost-field="([^"]+)""#, in: transition) == ["testhost.web.input"])
        #expect(!transition.contains(".focus("))
        #expect(!transition.contains(" hidden"))
    }

    @Test func scriptsAndStylesCarrySPDXHeaders() throws {
        for page in try files(in: pagesDirectory) where ["js", "css", "html"].contains(page.pathExtension) {
            let head = try read(page).split(separator: "\n").prefix(5).joined(separator: "\n")
            #expect(head.contains("SPDX-License-Identifier: GPL-3.0-or-later"), "\(page.lastPathComponent)")
        }
    }
}

@Suite struct TestHostSourcesTests {
    /// QA-R10 field list, in the contract's order, then the second window's fields (QA-R11 per-window rules).
    @Test func everyFieldKindIsDeclared() throws {
        #expect(
            try testHostFieldIDs() == [
                "testhost.native.textField", "testhost.native.textView", "testhost.web.input", "testhost.web.textarea",
                "testhost.web.contentEditable", "testhost.sim.addressBar", "testhost.sim.sheetCell",
                "testhost.native.password", "testhost.second.textField", "testhost.second.textView",
                "testhost.second.plainField", "testhost.second.escapeField",
            ])
    }

    /// The second window builds every one of its fields with label and hint, and the escape field marks Escape.
    @Test func secondWindowBuildsItsFields() throws {
        let second = try read(sourcesDirectory.appendingPathComponent("SecondWindow.swift"))
        for field in ["secondTextField", "secondTextView", "secondPlainField", "escapeField"] {
            #expect(second.contains("access[." + field + "]"), "\(field)")
        }
        #expect(second.contains("override func cancelOperation") && second.contains("static let marker = \"<esc>\""))
        #expect(EscapeMarker.value == "<esc>")
    }

    /// The harness drives TestHost through these controls: Reset fields before each scenario, Command+1, 2, 3 to
    /// move the focus inside a key script (BenchWorkload, per-window scenarios).
    @Test func resetButtonAndFocusShortcutsExist() throws {
        let sources = try files(in: sourcesDirectory).map(read).joined(separator: "\n")
        #expect(sources.contains("\"" + TestHostControls.resetFields + "\""))
        #expect(sources.contains("setAccessibilityLabel(\"Reset fields\")"))
        for (key, selector) in [("1", "focusMainField"), ("2", "focusSecondWindowField"), ("3", "focusAddressBar")] {
            #expect(sources.contains("#selector(TestHostApp." + selector + "(_:)), \"" + key + "\")"), "\(selector)")
        }
        #expect(BenchWorkload.focusKeys == ["command+1", "command+2", "command+3"])
        for id in [TestHostControls.mainTextField, TestHostControls.secondTextField, TestHostControls.addressBar] {
            #expect(try testHostFieldIDs().contains(id), "\(id)")
        }
    }

    /// Profile `testhost-reproductions` matches the local pages' fields by DOM class.
    @Test func pagesCarryTheClassesTheProfilesMatch() throws {
        let profiles = try repositoryProfiles()
        let classes = profiles.flatMap(\.ruleOverrides).flatMap { override -> [String] in
            guard case .array(let items)? = override.rule["match"]?["ax"]?["domClasses"] else { return [] }
            return items.compactMap(\.stringValue)
        }
        #expect(classes.count == 3)
        let pages = try files(in: pagesDirectory).filter { $0.pathExtension == "html" }.map(read).joined()
        for name in classes {
            #expect(pages.range(of: #"class="[^"]*\b"# + name + #"\b"#, options: .regularExpression) != nil, "\(name)")
        }
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

    /// Brand and network rules for the app sources: no bundle-ID-shaped literal (same pattern as
    /// scripts/lint-bundle-ids.sh, PLT-R501), no remote URL, no print.
    @Test func sourcesStayBrandNeutralAndOffline() throws {
        let tlds =
            "com|org|net|io|dev|app|vn|me|co|ai|so|sh|tv|us|uk|de|fr|jp|cn|ru|ca|au|eu|nl|se|ch|info|biz|xyz|tech|cloud|edu|gov"
        let bundleShaped = #""((?:"# + tlds + #")\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)""#
        #expect(!matches(bundleShaped, in: #"let x = "co.example""#).isEmpty)  // the check is not vacuous
        for file in try files(in: sourcesDirectory) {
            let text = try read(file)
            #expect(matches(bundleShaped, in: text).isEmpty, "\(file.lastPathComponent)")
            #expect(text.range(of: "http", options: .caseInsensitive) == nil, "\(file.lastPathComponent)")
            #expect(!text.contains("print("), "\(file.lastPathComponent)")
        }
    }

    /// PLT-R461 step 3: the `paste` strategy posts Command+V, which AppKit turns into `paste:` only through a menu
    /// key equivalent. Without an Edit menu TestHost ignored it and `testhost.privacyCanary.paste` lost every
    /// composed letter in the VM (integration-suite.md section 10.5); real apps all have the standard Edit menu.
    @Test func editMenuHasTheStandardKeyEquivalents() throws {
        let app = try read(sourcesDirectory.appendingPathComponent("TestHostApp.swift"))
        for (selector, key) in [
            ("NSText.cut(_:)", "x"), ("NSText.copy(_:)", "c"), ("NSText.paste(_:)", "v"),
            ("NSText.selectAll(_:)", "a"),
        ] {
            #expect(app.contains(#"#selector("# + selector + #"), ""# + key + #"")"#), "\(selector)")
        }
        #expect(app.contains(#"NSMenu(title: "Edit")"#))
    }

    @Test func pageHandlerNeverBecomesTheDefaultHTMLViewer() throws {
        let plist = try read(repositoryRoot.appendingPathComponent("TestHost/Info.plist"))
        #expect(plist.contains("<key>LSHandlerRank</key>\n\t\t\t<string>None</string>"))
    }
}
