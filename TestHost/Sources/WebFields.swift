// SPDX-License-Identifier: GPL-3.0-or-later
//
// WKWebView part of the test host (QA-R10): loads a local page from the bundle (no network, 13.2), and mirrors
// the DOM value of every element marked `data-testhost-field` into a native read-only field with the same
// accessibility identifier, so the runner reads web fields through AX exactly like native ones. Focusing a
// mirror (AXFocused) moves keyboard focus into the page element it mirrors.

import AppKit
import WebKit

/// Read-only native field showing a DOM value. Becoming first responder, or an AX focus request (the runner's
/// `focusField`), forwards focus to the page. The AX path is explicit: in the first VM runs the request left the
/// previously focused native field first responder, and the web scenarios typed into it.
final class MirrorTextField: NSTextField {
    var onFocusRequest: (@MainActor @Sendable () -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let onFocusRequest { DispatchQueue.main.async(execute: onFocusRequest) }
        return accepted
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        if accessibilityFocused, let onFocusRequest { DispatchQueue.main.async(execute: onFocusRequest) }
    }
}

@MainActor
final class WebFieldsController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Bundled local pages, in picker order. `fields.html` holds the QA-R10 input, textarea and contenteditable.
    static let pages = [
        "fields.html", "inline-autocomplete.html", "edit-mode-transition.html", "contenteditable-composer.html",
    ]
    static let messageHandler = "testhost"
    static let mirroredFields: [TestHostField] = [.webInput, .webTextarea, .webContentEditable]

    let webView: WKWebView
    let picker = NSPopUpButton()
    private(set) var mirrors: [TestHostField: MirrorTextField] = [:]
    /// A focus request that arrived while a page was loading; applied once it finished.
    private var pendingFocus: TestHostField?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 220), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: Self.messageHandler)
        webView.navigationDelegate = self
        webView.setAccessibilityLabel("Local test page")
        webView.setAccessibilityHelp("Web page with an input, a textarea and a contenteditable element.")
        for field in Self.mirroredFields { mirrors[field] = makeMirror(field) }
        picker.addItems(withTitles: Self.pages)
        picker.target = self
        picker.action = #selector(pickPage(_:))
        picker.setAccessibilityIdentifier("testhost.web.pagePicker")
        picker.setAccessibilityLabel("Local test page")
        picker.setAccessibilityHelp("Chooses which bundled test page the web view shows.")
    }

    private func makeMirror(_ field: TestHostField) -> MirrorTextField {
        let mirror = MirrorTextField(string: "")
        mirror.isEditable = false
        mirror.isSelectable = true
        mirror.setAccessibilityIdentifier(field.rawValue)
        mirror.setAccessibilityLabel("Mirror of " + field.rawValue)
        mirror.setAccessibilityHelp("Shows the current value of the page element; focusing it focuses that element.")
        mirror.onFocusRequest = { @MainActor [weak self] in self?.focusElement(field) }
        return mirror
    }

    // MARK: Pages

    /// Directory of the bundled pages (XcodeGen may copy the folder or flatten its files).
    static var pagesDirectory: URL? {
        let bundle = Bundle.main
        let url =
            bundle.url(forResource: "fields", withExtension: "html", subdirectory: "Pages")
            ?? bundle.url(forResource: "fields", withExtension: "html")
        return url?.deletingLastPathComponent()
    }

    func loadPage(named name: String) {
        guard let directory = Self.pagesDirectory else { return }
        load(directory.appendingPathComponent(name))
    }

    /// Loads a local file page. Anything that is not a `file:` URL to an .html file is ignored (no network).
    func load(_ url: URL) {
        guard url.isFileURL, url.pathExtension == "html" else { return }
        for mirror in mirrors.values { mirror.stringValue = "" }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        if let index = Self.pages.firstIndex(of: url.lastPathComponent) { picker.selectItem(at: index) }
    }

    @objc private func pickPage(_ sender: NSPopUpButton) {
        loadPage(named: Self.pages[max(0, sender.indexOfSelectedItem)])
    }

    /// Reset fields: back to `fields.html` when an earlier scenario opened another page, so scenarios without an
    /// `openURL` step (web input, textarea, contenteditable) always find their elements.
    func resetPage() {
        guard webView.url?.lastPathComponent != Self.pages[0] else { return }
        loadPage(named: Self.pages[0])
    }

    /// Blocks every navigation away from local files (13.2: pages carry no network references).
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isLocal = navigationAction.request.url?.isFileURL ?? false
        decisionHandler(isLocal || navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    // MARK: Mirroring

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let raw = body["field"] as? String,
            let field = TestHostField(rawValue: raw), let value = body["value"] as? String
        else { return }
        mirrors[field]?.stringValue = value
    }

    func text(of field: TestHostField) -> String { mirrors[field]?.stringValue ?? "" }

    func reset(_ field: TestHostField) {
        mirrors[field]?.stringValue = ""
        webView.evaluateJavaScript("window.TestHost && window.TestHost.reset(" + Self.quoted(field.rawValue) + ")")
    }

    /// Moves the page's focus first, then makes the web view first responder: WebKit gives focus back to the page's
    /// previously focused element when the view becomes first responder, so focusing the view first showed the app
    /// under test two focus changes, the second one only after the first keys (the VM runs left the first word in
    /// the web textarea untransformed).
    func focusElement(_ field: TestHostField) {
        guard !webView.isLoading else {
            pendingFocus = field
            return
        }
        webView.evaluateJavaScript("window.TestHost && window.TestHost.focus(" + Self.quoted(field.rawValue) + ")") {
            [weak self] _, _ in
            guard let self else { return }
            self.webView.window?.makeFirstResponder(self.webView)
        }
    }

    /// Reset fields: no element of the page keeps the focus, so the next focus request is the only focus change.
    func blurPage() {
        webView.evaluateJavaScript(
            "document.activeElement && document.activeElement.blur && document.activeElement.blur()")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let field = pendingFocus else { return }
        pendingFocus = nil
        focusElement(field)
    }

    /// Field identifiers are fixed ASCII; quoting keeps the script well-formed anyway.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// `WKUserContentController` retains its handlers; this breaks the cycle with the controller.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
