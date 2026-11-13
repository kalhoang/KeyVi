// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Setup routing, readbacks (AX, WebDriver, terminal capture, human), brand-neutral targets. Fakes only.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

private let testHostID = bundle("org.example.product.dev.testhost")
private let targets = HarnessTargets(
    testHostBundleID: testHostID, appUnderTestBundleID: bundle("org.example.product.dev"),
    pagesDirectory: URL(fileURLWithPath: "/repo/TestHost/Resources/Pages", isDirectory: true))

@Suite struct HarnessTargetsTests {
    @Test func brandEnvironmentParsing() {
        let text = "# comment\nAPP_SLUG=\"slug\"\n  APP_BUNDLE_ID_DEV = org.example.dev \nnot a line\n=x\nEMPTY=\"\"\n"
        #expect(
            BrandEnvironment.parse(text) == ["APP_SLUG": "slug", "APP_BUNDLE_ID_DEV": "org.example.dev", "EMPTY": ""])
    }

    @Test func testHostAliasResolvesFromTheBrandFile() {
        let resolved = HarnessTargets.resolve(
            repository: URL(fileURLWithPath: "/repo"), brandEnvironment: "APP_BUNDLE_ID_DEV=\"org.example.product.dev\""
        )
        #expect(resolved.testHostBundleID == testHostID)
        #expect(resolved.appUnderTestBundleID == bundle("org.example.product.dev"))
        #expect(resolved.resolve(bundle(HarnessTargets.testHostAlias)) == testHostID)
        #expect(resolved.resolve(bundle("com.example.Editor")) == bundle("com.example.Editor"))
        #expect(resolved.pagesDirectory.path == "/repo/TestHost/Resources/Pages")
    }

    @Test func explicitIDsWinAndMissingBrandLeavesTheAliasUnresolved() {
        let explicit = HarnessTargets.resolve(
            repository: URL(fileURLWithPath: "/repo"), brandEnvironment: "APP_BUNDLE_ID_DEV=a.b",
            testHost: "c.d", appUnderTest: "e.f")
        #expect(explicit.testHostBundleID == bundle("c.d"))
        #expect(explicit.appUnderTestBundleID == bundle("e.f"))
        let missing = HarnessTargets.resolve(repository: URL(fileURLWithPath: "/repo"), brandEnvironment: nil)
        #expect(missing.resolve(bundle(HarnessTargets.testHostAlias)) == nil)
        #expect(
            HarnessTargets.resolve(repository: URL(fileURLWithPath: "/r"), brandEnvironment: "APP_BUNDLE_ID_DEV=")
                .testHostBundleID == nil)
    }

    @Test func holderAliasResolvesInExpectations() {
        let aliased = makeScenario(expect: .init(paused: true, holderBundleId: bundle(HarnessTargets.testHostAlias)))
        #expect(targets.resolvingExpectation(of: aliased).expect.holderBundleId == testHostID)
        let real = makeScenario(expect: .init(holderBundleId: bundle("com.example.Holder")))
        #expect(targets.resolvingExpectation(of: real) == real)
        #expect(targets.resolvingExpectation(of: makeScenario()) == makeScenario())
    }

    @Test func pagesPlaceholderExpandsToAFileURL() {
        #expect(targets.expand("{pages}/fields.html") == "file:///repo/TestHost/Resources/Pages/fields.html")
        #expect(targets.expand("file:///other") == "file:///other")
    }
}

@Suite struct ScenarioSetupRouterTests {
    private func router(
        _ system: FakeSystemActions, transport: FakeTransport? = nil,
        fileSystem: InMemoryFileSystem = InMemoryFileSystem(),
        clock: ManualClock = ManualClock()
    ) throws -> ScenarioSetupRouter {
        let endpoints =
            transport.map { _ in [bundle("com.example.Browser"): URL(string: "http://127.0.0.1:4444")!] } ?? [:]
        let drivers = try WebDriverClients(endpoints: endpoints, transport: transport ?? FakeTransport(responses: [:]))
        return ScenarioSetupRouter(
            system: system, targets: targets, webDrivers: drivers,
            terminal: .init(fileSystem: fileSystem, captureFile: URL(fileURLWithPath: "/out/capture.txt")), clock: clock
        )
    }

    @Test func nativeStepsGoToTheSystemWithAliasesResolved() async throws {
        let system = FakeSystemActions()
        let scenario = makeScenario(target: HarnessTargets.testHostAlias)
        let router = try router(system)
        for step: Scenario.SetupStep in [
            .init(action: .launch), .init(action: .launch, value: "com.example.Other"),
            .init(action: .openURL, value: "{pages}/fields.html"), .init(action: .seedHistory, value: "file:///h"),
            .init(action: .focusField, value: "testhost.native.textField"),
            .init(action: .selectInputSource, value: "com.apple.keylayout.ABC"),
            .init(action: .setSecureInput, value: "on"),
            .init(action: .setSecureInput, value: "off"),
        ] {
            try await router.perform(step, for: scenario)
        }
        let id = testHostID.rawValue
        #expect(
            system.calls.all == [
                "launch " + id, "launch com.example.Other",
                "open file:///repo/TestHost/Resources/Pages/fields.html in " + id,
                "seed file:///h in " + id, "focus testhost.native.textField in " + id, "source com.apple.keylayout.ABC",
                "secure true in " + id, "secure false in " + id,
            ])
    }

    @Test func waitAdvancesTheInjectedClock() async throws {
        let clock = ManualClock()
        let before = clock.now().nanoseconds
        try await router(FakeSystemActions(), clock: clock).perform(
            .init(action: .wait, value: "250"), for: makeScenario())
        #expect(clock.now().nanoseconds - before == 250_000_000)
    }

    @Test func invalidValuesAndUnresolvedTargetsThrow() async throws {
        let router = try router(FakeSystemActions())
        await #expect(throws: HarnessSetupError.invalidValue(action: "wait")) {
            try await router.perform(.init(action: .wait, value: "x"), for: makeScenario())
        }
        await #expect(throws: HarnessSetupError.invalidValue(action: "focusField")) {
            try await router.perform(.init(action: .focusField), for: makeScenario())
        }
        await #expect(throws: HarnessSetupError.invalidValue(action: "selectInputSource")) {
            try await router.perform(.init(action: .selectInputSource, value: "sha256:x"), for: makeScenario())
        }
        let unresolved = ScenarioSetupRouter(
            system: FakeSystemActions(),
            targets: HarnessTargets(
                testHostBundleID: nil, appUnderTestBundleID: nil, pagesDirectory: URL(fileURLWithPath: "/")),
            webDrivers: WebDriverClients(clients: [:]), terminal: nil, clock: ManualClock())
        await #expect(throws: HarnessSetupError.unresolvedTarget(HarnessTargets.testHostAlias)) {
            try await unresolved.perform(
                .init(action: .launch), for: makeScenario(target: HarnessTargets.testHostAlias))
        }
    }

    @Test func terminalLaunchWritesTheCaptureScriptAndStartsIt() async throws {
        let system = FakeSystemActions()
        let fileSystem = InMemoryFileSystem()
        let scenario = makeScenario(target: "com.example.Terminal", readback: .terminalCapture)
        try await router(system, fileSystem: fileSystem).perform(.init(action: .launch), for: scenario)
        #expect(system.calls.all == ["capture in com.example.Terminal -> capture.txt"])
        let script = try fileSystem.readData(at: URL(fileURLWithPath: "/out/capture.txt.zsh"), maxBytes: 4096)
        #expect(String(decoding: script, as: UTF8.self) == TerminalCaptureReadback.zshScript)
        // Launching another app from a terminal scenario is a plain launch.
        try await router(system).perform(.init(action: .launch, value: "com.example.Other"), for: scenario)
        #expect(system.calls.all.last == "launch com.example.Other")
    }

    @Test func terminalLaunchWithoutCaptureConfigurationFails() async {
        let router = ScenarioSetupRouter(
            system: FakeSystemActions(), targets: targets, webDrivers: WebDriverClients(clients: [:]), terminal: nil,
            clock: ManualClock())
        await #expect(throws: HarnessReadbackError.unavailable(.terminalCapture)) {
            try await router.perform(.init(action: .launch), for: makeScenario(readback: .terminalCapture))
        }
    }

    @Test func webdriverScenariosNavigateAndFocusThroughTheDriver() async throws {
        let transport = FakeTransport(responses: [
            "/session": (200, #"{"value":{"sessionId":"S1"}}"#), "/url": (200, #"{"value":null}"#),
            "/element": (200, #"{"value":{"element-6066-11e4-a52e-4f735466cecf":"E7"}}"#),
            "/click": (200, #"{"value":null}"#),
        ])
        let system = FakeSystemActions()
        let router = try router(system, transport: transport)
        let scenario = makeScenario(target: "com.example.Browser", readback: .webdriver)
        try await router.perform(.init(action: .openURL, value: "{pages}/fields.html"), for: scenario)
        try await router.perform(.init(action: .openURL, value: "file:///second"), for: scenario)
        try await router.perform(.init(action: .focusField, value: "#composer"), for: scenario)
        #expect(system.calls.all.isEmpty)
        #expect(
            transport.requests.all.map(\.path) == [
                "/session", "/session/S1/url", "/session/S1/url", "/session/S1/element", "/session/S1/element/E7/click",
            ])
        #expect(transport.requests.all[1].body.contains("file:///repo/TestHost/Resources/Pages/fields.html"))
        #expect(transport.requests.all[3].body.contains("#composer"))
    }
}

@Suite struct WebDriverClientTests {
    @Test func onlyLoopbackEndpointsAreAccepted() {
        #expect(throws: WebDriverError.nonLoopbackEndpoint("http://example.com:4444")) {
            _ = try WebDriverClient(
                transport: FakeTransport(responses: [:]), endpoint: URL(string: "http://example.com:4444")!)
        }
        #expect(throws: WebDriverError.noEndpoint(target: "com.example.Browser")) {
            _ = try WebDriverClients(clients: [:]).client(for: bundle("com.example.Browser"))
        }
    }

    @Test func readsFieldTextWithAScript() async throws {
        let transport = FakeTransport(responses: [
            "/session": (200, #"{"value":{"sessionId":"S"}}"#), "/execute/sync": (200, #"{"value":"tiếng việt"}"#),
        ])
        let client = try WebDriverClient(transport: transport, endpoint: URL(string: "http://localhost:9515")!)
        await #expect(throws: WebDriverError.noSession(target: "http://localhost:9515")) {
            _ = try await client.fieldText(selector: nil)
        }
        try await client.startSession()
        #expect(await client.hasSession)
        #expect(try await client.fieldText(selector: "#composer") == "tiếng việt")
        #expect(transport.requests.all.last?.body.contains(##""args":["#composer"]"##) == true)
    }

    @Test func httpAndShapeErrors() async throws {
        let failing = try WebDriverClient(
            transport: FakeTransport(responses: ["/session": (500, "{}")]), endpoint: URL(string: "http://127.0.0.1:1")!
        )
        await #expect(throws: WebDriverError.http(status: 500)) { try await failing.startSession() }
        let malformed = try WebDriverClient(
            transport: FakeTransport(responses: ["/session": (200, #"{"value":{}}"#)]),
            endpoint: URL(string: "http://127.0.0.1:1")!)
        await #expect(throws: WebDriverError.malformedResponse) { try await malformed.startSession() }
        let notJSON = try WebDriverClient(
            transport: FakeTransport(responses: ["/session": (200, "nope")]),
            endpoint: URL(string: "http://127.0.0.1:1")!)
        await #expect(throws: WebDriverError.malformedResponse) { try await notJSON.startSession() }
        let transport = FakeTransport(responses: [
            "/session": (200, #"{"value":{"sessionId":"S"}}"#), "/element": (200, #"{"value":{}}"#),
            "/execute/sync": (200, #"{"value":null}"#),
        ])
        let client = try WebDriverClient(transport: transport, endpoint: URL(string: "http://127.0.0.1:1")!)
        try await client.startSession()
        await #expect(throws: WebDriverError.malformedResponse) { try await client.click(selector: "#x") }
        await #expect(throws: WebDriverError.malformedResponse) { _ = try await client.fieldText(selector: nil) }
    }
}

@Suite struct ReadbackRouterTests {
    private let capture = URL(fileURLWithPath: "/out/capture.txt")

    private func router(
        ax: (any AXFieldReader)? = FixedAXReader(text: "ax text"),
        fileSystem: InMemoryFileSystem = InMemoryFileSystem(),
        human: HumanConfirmationReadback? = nil, webDrivers: WebDriverClients = WebDriverClients(clients: [:])
    ) -> ReadbackRouter {
        ReadbackRouter(
            targets: targets, ax: ax, webDrivers: webDrivers,
            terminal: TerminalCaptureReadback(fileSystem: fileSystem, captureFile: capture), human: human)
    }

    @Test func axReadback() async throws {
        #expect(try await router().currentText(of: makeScenario()) == "ax text")
        await #expect(throws: HarnessReadbackError.unavailable(.ax)) {
            _ = try await router(ax: nil).currentText(of: makeScenario())
        }
    }

    @Test func terminalCaptureReadsTheLastLine() async throws {
        let fileSystem = InMemoryFileSystem()
        let scenario = makeScenario(readback: .terminalCapture)
        await #expect(throws: HarnessReadbackError.captureMissing(path: "/out/capture.txt")) {
            _ = try await router(fileSystem: fileSystem).currentText(of: scenario)
        }
        try fileSystem.writeAtomically(Data("first\nmuốn chào \n\n".utf8), to: capture, permissions: .ownerOnlyFile)
        #expect(try await router(fileSystem: fileSystem).currentText(of: scenario) == "muốn chào ")
        try fileSystem.writeAtomically(Data(), to: capture, permissions: .ownerOnlyFile)
        #expect(try await router(fileSystem: fileSystem).currentText(of: scenario) == "")
    }

    @Test func humanReadbackConfirmsOrTakesTheTypedText() async throws {
        let scenario = makeScenario(readback: .human)
        let confirming = FakeLineReader(answer: "")
        #expect(
            try await router(human: HumanConfirmationReadback(reader: confirming)).currentText(of: scenario) == "đi")
        #expect(confirming.prompts.all.first?.contains("[sample.scenario]") == true)
        let typed = HumanConfirmationReadback(reader: FakeLineReader(answer: "ddi"))
        #expect(try await router(human: typed).currentText(of: scenario) == "ddi")
        let absent = HumanConfirmationReadback(reader: FakeLineReader(answer: nil))
        await #expect(throws: HumanReadbackRequired.self) {
            _ = try await router(human: absent).currentText(of: scenario)
        }
        await #expect(throws: HumanReadbackRequired.self) { _ = try await router().currentText(of: scenario) }
    }

    @Test func webdriverReadbackUsesTheFocusedSelector() async throws {
        let transport = FakeTransport(responses: [
            "/session": (200, #"{"value":{"sessionId":"S"}}"#), "/execute/sync": (200, #"{"value":"đi"}"#),
        ])
        let browser = bundle("com.example.Browser")
        let client = try WebDriverClient(transport: transport, endpoint: URL(string: "http://127.0.0.1:4444")!)
        try await client.startSession()
        let scenario = makeScenario(
            target: browser.rawValue,
            setup: [.init(action: .openURL, value: "file:///p"), .init(action: .focusField, value: "#a")],
            readback: .webdriver)
        let text = try await router(webDrivers: WebDriverClients(clients: [browser: client])).currentText(of: scenario)
        #expect(text == "đi")
        #expect(transport.requests.all.last?.body.contains(##""#a""##) == true)
    }

    @Test func unresolvedTargetThrows() async {
        let router = ReadbackRouter(
            targets: HarnessTargets(
                testHostBundleID: nil, appUnderTestBundleID: nil, pagesDirectory: URL(fileURLWithPath: "/")),
            ax: nil, webDrivers: WebDriverClients(clients: [:]), terminal: nil, human: nil)
        await #expect(throws: HarnessSetupError.self) {
            _ = try await router.currentText(of: makeScenario(target: HarnessTargets.testHostAlias))
        }
        let noTerminal = ReadbackRouter(
            targets: targets, ax: nil, webDrivers: WebDriverClients(clients: [:]), terminal: nil, human: nil)
        await #expect(throws: HarnessReadbackError.unavailable(.terminalCapture)) {
            _ = try await noTerminal.currentText(of: makeScenario(readback: .terminalCapture))
        }
    }

    @Test func captureScriptUsesZleAndAppends() {
        #expect(TerminalCaptureReadback.zshScript.hasPrefix("#!/bin/zsh -f"))
        #expect(TerminalCaptureReadback.zshScript.contains("vared"))
        #expect(TerminalCaptureReadback.zshScript.contains(#">> "$capture""#))
    }
}
