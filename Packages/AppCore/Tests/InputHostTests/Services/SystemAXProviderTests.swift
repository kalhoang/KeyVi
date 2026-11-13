// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pure parts of the production AX wrapper (PLT-R380, PLT-R384). No AX message is sent: calling AX needs the
// Accessibility permission, which tests never request (the real path runs on the self-hosted runner). The
// attribute reader runs over an injected read table; its elements are local references made with
// `AXUIElementCreateApplication` for unused pids, which sends nothing.

import ApplicationServices
import Foundation
import Injection
import RealtimeSupport
import Testing

@testable import InputHost

@Suite("SystemAXProvider pure parts (PLT-R380, PLT-R384)")
struct SystemAXProviderTests {
    @Test func notificationNamesRoundTrip() {
        for kind in AXNotificationKind.allCases {
            #expect(AXNotificationNames.kind(for: AXNotificationNames.name(for: kind)) == kind)
        }
        #expect(AXNotificationNames.name(for: .focusedElementChanged) == kAXFocusedUIElementChangedNotification)
        #expect(AXNotificationNames.kind(for: "AXSomethingElse") == nil)
    }

    @Test func handlerBoxDeliversOnlyKnownNotifications() {
        let received = Mutex<[AXNotificationKind]>([])
        let box = AXObserverHandlerBox { kind in received.withLock { $0.append(kind) } }
        box.deliver(kAXTitleChangedNotification)
        box.deliver("AXUnknown")
        #expect(received.withLock { $0 } == [.titleChanged])
    }

    @Test func messagingTimeoutIs100Milliseconds() {
        #expect(SystemAXProvider.messagingTimeout == 0.1)
        #expect(SystemAXProvider.maximumAncestors == 6)
    }

    @Test func errorMapping() {
        let timedOut: AXCallResult<Int32> = AXRead.failure(.cannotComplete)
        guard case .timedOut = timedOut else {
            Issue.record("cannotComplete must be a timeout")
            return
        }
        let failed: AXCallResult<Int32> = AXRead.failure(.illegalArgument)
        guard case .failed(let code) = failed else {
            Issue.record("expected failure")
            return
        }
        #expect(code == AXError.illegalArgument.rawValue)
        let outcome = AXRead.Outcome<String>.success("AXButton")
        #expect(outcome.value == .some("AXButton"))
        #expect(AXRead.Outcome<String>.timedOut.value == nil)
        guard case .unavailable = AXRead.Outcome<String>.unavailable.flatMap({ _ in AXCallResult<Int>.success(1) })
        else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test func readsTheBoundedAttributesOfAFocusedElement() {
        let table = AXReadTable()
        table.setStandardField()
        let request = AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: true)
        guard case .success(let attributes) = table.reader().read(request: request) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.role == "AXTextArea")
        #expect(attributes.subrole == "AXSearchField")
        #expect(attributes.identifier == "query")
        #expect(attributes.domClasses == ["search", "input"])
        #expect(attributes.editable == true)
        #expect(attributes.ancestorRoles == ["AXGroup", "AXWebArea"])
        #expect(attributes.documentURL == "https://example.test/page")
        #expect(attributes.windowTitle == "Window")
    }

    @Test func titleAndURLAreReadOnlyWhenRequestedPLTR383() {
        let table = AXReadTable()
        table.setStandardField()
        let request = AXAttributeRequest(includeDocumentURL: false, includeWindowTitle: false)
        guard case .success(let attributes) = table.reader().read(request: request) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.documentURL == nil)
        #expect(attributes.windowTitle == nil)
        #expect(!table.requested(kAXWindowAttribute))
        #expect(!table.requested(kAXURLAttribute))
    }

    /// PLT-R384: a timeout in any sub-read is a timeout of the whole read, so the core counts it for the breaker;
    /// reading stops at the first one, so one refresh spends at most one more messaging timeout.
    @Test(arguments: [
        AXReadTable.Hang.parent, .ancestorRole, .window, .title, .url, .subrole, .identifier, .domClasses,
    ])
    func aTimeoutInAnySubReadTimesTheReadOutPLTR384(_ hang: AXReadTable.Hang) {
        let table = AXReadTable()
        table.setStandardField()
        table.hang(hang)
        let request = AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: true)
        guard case .timedOut = table.reader().read(request: request) else {
            Issue.record("expected a timeout for \(hang)")
            return
        }
        #expect(table.readsAfterTimeout == 0)
    }

    @Test func roleAndSettableOutcomesMapToTheCallResult() {
        let table = AXReadTable()
        table.setStandardField()
        table.set(table.field, kAXRoleAttribute, .unavailable)
        guard case .unavailable = table.reader().read(request: AXAttributeRequest.none) else {
            Issue.record("expected unavailable")
            return
        }
        table.set(table.field, kAXRoleAttribute, .timedOut)
        guard case .timedOut = table.reader().read(request: AXAttributeRequest.none) else {
            Issue.record("expected a role timeout")
            return
        }
        table.setStandardField()
        table.settable = (.cannotComplete, false)
        guard case .timedOut = table.reader().read(request: AXAttributeRequest.none) else {
            Issue.record("expected a settable timeout")
            return
        }
        table.settable = (.attributeUnsupported, false)
        guard case .success(let attributes) = table.reader().read(request: AXAttributeRequest.none) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.editable == nil)
    }

    /// 02-platform.md 5.5: browser chrome (the omnibox under a toolbar) is not inside the web area, so no URL
    /// is read for it even though the window shows a page; nothing beyond the window is walked.
    @Test func browserChromeHasNoDocumentURL() {
        let table = AXReadTable()
        let toolbar = AXReadTable.element(10)
        let application = AXReadTable.element(11)
        table.set(table.field, kAXRoleAttribute, .success("AXTextField" as CFString))
        table.chain(from: table.field, through: [(table.group, "AXGroup"), (toolbar, "AXToolbar")])
        table.chain(from: toolbar, through: [(table.window, "AXWindow"), (application, "AXApplication")])
        table.set(table.webArea, kAXRoleAttribute, .success(AXAttributeReader.webAreaRole as CFString))
        table.set(table.webArea, kAXURLAttribute, .success(URL(string: "https://example.test/sheet")! as CFURL))
        let request = AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: false)
        guard case .success(let attributes) = table.reader().read(request: request) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.documentURL == nil)
        #expect(attributes.ancestorRoles == ["AXGroup", "AXToolbar", "AXWindow", "AXApplication"])
        #expect(!table.requested(kAXURLAttribute))
    }

    /// The focused element can be the web area itself.
    @Test func theFocusedWebAreaGivesItsOwnURL() {
        let table = AXReadTable()
        table.set(table.field, kAXRoleAttribute, .success(AXAttributeReader.webAreaRole as CFString))
        table.set(table.field, kAXURLAttribute, .success(URL(string: "https://example.test/page")! as CFURL))
        let request = AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: false)
        guard case .success(let attributes) = table.reader().read(request: request) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.documentURL == "https://example.test/page")
    }

    /// Web content nests deeper than the six ancestors used for matching: the search for the web area goes on
    /// (only when the URL is requested) and reports the chain up to it, so the core can see it is web content.
    @Test func aDeepWebAreaIsFoundAndReportedWithItsChain() {
        let table = AXReadTable()
        table.set(table.field, kAXRoleAttribute, .success("AXTextArea" as CFString))
        let groups = (1...8).map { (AXReadTable.element(20 + $0), "AXGroup") }
        table.chain(from: table.field, through: groups + [(table.webArea, AXAttributeReader.webAreaRole)])
        table.set(table.webArea, kAXURLAttribute, .success(URL(string: "https://example.test/deep")! as CFURL))
        let request = AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: false)
        guard case .success(let attributes) = table.reader().read(request: request) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.documentURL == "https://example.test/deep")
        #expect(attributes.ancestorRoles == Array(repeating: "AXGroup", count: 8) + [AXAttributeReader.webAreaRole])
        guard case .success(let plain) = table.reader().read(request: AXAttributeRequest.none) else {
            Issue.record("expected attributes")
            return
        }
        #expect(plain.ancestorRoles.count == SystemAXProvider.maximumAncestors)
    }

    /// The extended search is bounded and reports nothing extra when it finds no web area.
    @Test func theWebAreaSearchIsBounded() {
        let table = AXReadTable()
        table.set(table.field, kAXRoleAttribute, .success("AXTextArea" as CFString))
        let groups = (1...30).map { (AXReadTable.element(40 + $0), "AXGroup") }
        table.chain(from: table.field, through: groups)
        let request = AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: false)
        guard case .success(let attributes) = table.reader().read(request: request) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.documentURL == nil)
        #expect(attributes.ancestorRoles.count == SystemAXProvider.maximumAncestors)
        #expect(table.parentReads == SystemAXProvider.maximumWebAreaDepth)
    }

    @Test func ancestorsStopAtSixLevelsAndMissingValuesAreNil() {
        let table = AXReadTable()
        var cursor = table.field
        table.set(cursor, kAXRoleAttribute, .success("AXTextField" as CFString))
        for level in 1...8 {
            let parent = AXReadTable.element(level)
            table.set(cursor, kAXParentAttribute, .success(parent))
            table.set(parent, kAXRoleAttribute, .success("AXGroup" as CFString))
            cursor = parent
        }
        table.set(table.field, kAXSubroleAttribute, .success(42 as CFNumber))  // wrong type: nil
        guard case .success(let attributes) = table.reader().read(request: AXAttributeRequest.none) else {
            Issue.record("expected attributes")
            return
        }
        #expect(attributes.ancestorRoles.count == SystemAXProvider.maximumAncestors)
        #expect(attributes.subrole == nil)
        #expect(attributes.identifier == nil)
        #expect(attributes.domClasses.isEmpty)
    }
}

extension AXAttributeRequest {
    fileprivate static let none = AXAttributeRequest(includeDocumentURL: false, includeWindowTitle: false)
}

/// Attribute values per (element, attribute); anything not set reads as "no value". Records reads made after
/// the first timeout.
final class AXReadTable {
    enum Hang: Sendable {
        case parent, ancestorRole, window, title, url, subrole, identifier, domClasses
    }

    private var values: [(element: AXUIElement, attribute: String, outcome: AXRead.Outcome<CFTypeRef>)] = []
    private var requestedAttributes: [String] = []
    private var timedOut = false
    private(set) var readsAfterTimeout = 0
    var settable: (error: AXError, settable: Bool) = (.success, true)

    /// Local element references for unused pids; creating them sends no AX message.
    static func element(_ index: Int) -> AXUIElement { AXUIElementCreateApplication(pid_t(2_000_000 + index)) }

    let field = AXReadTable.element(0)
    let group = AXReadTable.element(1)
    let webArea = AXReadTable.element(2)
    let window = AXReadTable.element(3)

    func set(_ element: AXUIElement, _ attribute: String, _ outcome: AXRead.Outcome<CFTypeRef>) {
        values.removeAll { CFEqual($0.element, element) && $0.attribute == attribute }
        values.append((element, attribute, outcome))
    }

    func setStandardField() {
        values = []
        settable = (.success, true)
        set(field, kAXRoleAttribute, .success("AXTextArea" as CFString))
        set(field, kAXSubroleAttribute, .success("AXSearchField" as CFString))
        set(field, AXAttributeReader.identifierAttribute, .success("query" as CFString))
        set(field, AXAttributeReader.domClassListAttribute, .success(["search", "input"] as CFArray))
        set(field, kAXParentAttribute, .success(group))
        set(group, kAXRoleAttribute, .success("AXGroup" as CFString))
        set(group, kAXParentAttribute, .success(webArea))
        set(webArea, kAXRoleAttribute, .success(AXAttributeReader.webAreaRole as CFString))
        set(webArea, kAXURLAttribute, .success(URL(string: "https://example.test/page")! as CFURL))
        set(field, kAXWindowAttribute, .success(window))
        set(window, kAXTitleAttribute, .success("Window" as CFString))
    }

    func hang(_ hang: Hang) {
        switch hang {
        case .parent: set(group, kAXParentAttribute, .timedOut)
        case .ancestorRole: set(group, kAXRoleAttribute, .timedOut)
        case .window: set(field, kAXWindowAttribute, .timedOut)
        case .title: set(window, kAXTitleAttribute, .timedOut)
        case .url: set(webArea, kAXURLAttribute, .timedOut)
        case .subrole: set(field, kAXSubroleAttribute, .timedOut)
        case .identifier: set(field, AXAttributeReader.identifierAttribute, .timedOut)
        case .domClasses: set(field, AXAttributeReader.domClassListAttribute, .timedOut)
        }
    }

    func requested(_ attribute: String) -> Bool { requestedAttributes.contains(attribute) }
    var parentReads: Int { requestedAttributes.filter { $0 == kAXParentAttribute }.count }

    /// `start` -> parents in order, each with its role.
    func chain(from start: AXUIElement, through parents: [(AXUIElement, String)]) {
        var cursor = start
        for (parent, role) in parents {
            set(cursor, kAXParentAttribute, .success(parent))
            set(parent, kAXRoleAttribute, .success(role as CFString))
            cursor = parent
        }
    }

    func reader() -> AXAttributeReader {
        timedOut = false
        readsAfterTimeout = 0
        requestedAttributes = []
        let functions = AXReadFunctions(
            copy: { element, attribute in self.copy(element, attribute) },
            isValueSettable: { _ in self.settable })
        return AXAttributeReader(element: field, functions: functions)
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> AXRead.Outcome<CFTypeRef> {
        if timedOut { readsAfterTimeout += 1 }
        requestedAttributes.append(attribute)
        let outcome = values.first { CFEqual($0.element, element) && $0.attribute == attribute }?.outcome
        if case .timedOut = outcome { timedOut = true }
        return outcome ?? .success(nil)
    }
}
