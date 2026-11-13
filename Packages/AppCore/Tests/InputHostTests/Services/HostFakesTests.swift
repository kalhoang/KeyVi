// SPDX-License-Identifier: GPL-3.0-or-later
//
// The W1-E fakes behave like the services they replace.

import AppModel
import CoreFoundation
import Foundation
import Testing

@testable import InputHost
@testable import TestSupport

@Suite("Host fakes")
struct HostFakesTests {
    /// Two inert sources must not compare equal: a run loop removing one would remove the other.
    @Test func fakeObservationSourcesAreDistinct() throws {
        let ax = FakeAXProvider()
        let first = try #require(ax.observe(pid: 1, notifications: [.focusedElementChanged]) { _ in })
        let second = try #require(ax.observe(pid: 1, notifications: [.focusedElementChanged]) { _ in })
        #expect(!CFEqual(first.runLoopSource, second.runLoopSource))
        first.invalidate()
        first.invalidate()
        #expect(ax.observedNotifications[1] == [.focusedElementChanged])
        second.invalidate()
        #expect(ax.observedNotifications.isEmpty)
    }

    /// Synthetic element references are distinct per (pid, element), also for pids that differ by 10,000.
    @Test func fakeElementReferencesAreDistinctPerPidAndElement() {
        let pairs: [(Int32, UInt16)] = [(100, 0), (100, 1), (10_100, 1), (100, 2), (99_999, 20_000), (1, 1)]
        let references = pairs.map { FakeAXProvider.elementReference(pid: $0.0, element: $0.1).element }
        for (i, first) in references.enumerated() {
            for second in references[(i + 1)...] { #expect(!CFEqual(first, second)) }
        }
        let again = FakeAXProvider.elementReference(pid: 10_100, element: 1).element
        #expect(CFEqual(references[2], again))
    }

    @Test func fakeAXFiltersTitleAndURLByRequest() throws {
        let ax = FakeAXProvider()
        let attributes = FocusAttributes(
            role: "AXTextField", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
            documentURL: "https://example.test", windowTitle: "Title")
        ax.focus(pid: 3, attributes: attributes, notify: nil)
        guard case .success(let app?) = ax.focusedApplication(),
            case .success(let element?) = ax.focusedElement(pid: app)
        else {
            Issue.record("no focus")
            return
        }
        guard
            case .success(let none) = ax.attributes(
                of: element, request: .init(includeDocumentURL: false, includeWindowTitle: false))
        else {
            Issue.record("no attributes")
            return
        }
        #expect(none.documentURL == nil && none.windowTitle == nil)
        guard
            case .success(let all) = ax.attributes(
                of: element, request: .init(includeDocumentURL: true, includeWindowTitle: true))
        else {
            Issue.record("no attributes")
            return
        }
        #expect(all.documentURL == "https://example.test" && all.windowTitle == "Title")
        guard
            case .unavailable = ax.attributes(
                of: AXFocusedElement(pid: 9, element: element.element),
                request: .init(includeDocumentURL: false, includeWindowTitle: false))
        else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test func fakePermissionProbeCountsRequests() {
        let probe = FakePermissionProbe(trusted: false, post: false, listen: false)
        probe.promptForAccessibility()
        #expect(!probe.requestListenEventAccess())
        #expect(!probe.requestPostEventAccess())
        #expect(probe.accessibilityPromptCount == 1)
        #expect(probe.listenRequestCount == 1)
        #expect(probe.postRequestCount == 1)
    }

    @Test func fakeProcessesComeBackAfterAdd() {
        let processes = FakeProcessIdentityProvider(processes: [])
        let app = FakeProcessIdentityProvider.process(pid: 5, bundle: "com.example.app")
        processes.add(app)
        processes.terminate(pid: 5)
        #expect(!processes.isAlive(5))
        processes.add(app)
        #expect(processes.isAlive(5))
        #expect(processes.runningApplications() == [app])
    }

    /// Same contract as the production inspector: the folder to search, depth counted from it (PLT-R510).
    @Test func fakeBundleInspectorSearchesTheGivenFolderWithinTheDepth() {
        let url = URL(fileURLWithPath: "/Applications/Sample.app")
        let inspector = FakeBundleInspector(bundles: [
            url: .init(
                frameworks: ["A.framework"], helpers: ["H.app"], files: ["Contents/Frameworks/x/libxul.dylib"],
                info: [:])
        ])
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        #expect(inspector.frameworkNames(in: url) == ["A.framework"])
        #expect(inspector.helperAppNames(in: url) == ["H.app"])
        #expect(inspector.containsFile(named: "libxul.dylib", in: frameworks, maxDepth: 2))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: frameworks, maxDepth: 1))
        #expect(
            !inspector.containsFile(
                named: "libxul.dylib", in: url.appendingPathComponent("Contents/MacOS"), maxDepth: 6))
        #expect(!inspector.containsFile(named: "libxul.dylib", in: URL(fileURLWithPath: "/Other.app"), maxDepth: 6))
        #expect(inspector.infoDictionary(of: url) == [:])
    }

    @Test @MainActor func fakeInputSourceProviderObservers() {
        let abc = InputSourceInfo.layout("com.apple.keylayout.ABC")
        let provider = FakeInputSourceProvider(current: abc, layouts: [:])
        var calls = 0
        let token = provider.observeChanges { calls += 1 }
        provider.select(abc)
        token.cancel()
        provider.notifyChange()
        #expect(calls == 1)
        #expect(provider.enabledSources().isEmpty)
        #expect(provider.layoutData(for: abc.id) == nil)
    }
}
