// SPDX-License-Identifier: GPL-3.0-or-later
//
// Setup performer and readbacks of `compat-harness` (PLT-R530, 13.2): the routing logic lives here and is
// tested with fakes; `SystemActions`, `AXFieldReader` and `LineReader` are implemented for real in
// CompatHarness/Live (NSWorkspace, AX, Text Input Sources, stdin) and only run on the self-hosted runner.

public import AppModel
public import Foundation

/// Operating-system actions behind the setup steps. Runner only.
public protocol SystemActions: Sendable {
    func launch(_ bundle: BundleKey) async throws
    func open(_ url: String, in bundle: BundleKey) async throws
    /// Visits `url` in the browser so it lands in the history used for inline autocomplete.
    func seedHistory(_ url: String, in bundle: BundleKey) async throws
    /// Focuses the element with this accessibility identifier in the app's frontmost window.
    func focusField(identifier: String, in bundle: BundleKey) async throws
    func selectInputSource(_ source: InputSourceID) async throws
    /// TestHost: presses its secure-input toggle. Other apps: their own secure keyboard entry switch.
    func setSecureInput(_ enabled: Bool, in bundle: BundleKey) async throws
    /// Terminal scenarios: opens a window of the terminal app running `zsh -f <script> <captureFile>`.
    func startTerminalCapture(in bundle: BundleKey, script: URL, captureFile: URL) async throws
    /// TestHost: presses its "Reset fields" button (`TestHostControls.resetFields`) when it is running, so every
    /// TestHost scenario starts from empty fields. Does nothing when TestHost is not running (its `launch` step
    /// then starts it with empty fields).
    func resetTestHostFields(in bundle: BundleKey) async throws
}

public enum HarnessSetupError: Error, Sendable, Hashable {
    case unresolvedTarget(String)
    case invalidValue(action: String)
}

/// Routes setup steps: resolves `local.testhost`, expands `{pages}`, sends page navigation and field focus to
/// WebDriver for `webdriver` scenarios, starts the capture shell for `terminalCapture` scenarios, sends `testHook`
/// to the app's integration hooks and everything else to `SystemActions`; `wait` suspends through the injected
/// `HarnessSleeper`. Before a TestHost scenario it clears TestHost's fields; after a scenario that revoked the
/// permission it restores it.
public struct ScenarioSetupRouter: ScenarioSetupPerformer {
    public struct TerminalCapture: Sendable {
        public var fileSystem: any FileSystem
        /// The capture file the readback reads; the script is written next to it as `<file>.zsh`.
        public var captureFile: URL

        public init(fileSystem: any FileSystem, captureFile: URL) {
            self.fileSystem = fileSystem
            self.captureFile = captureFile
        }
    }

    private let system: any SystemActions
    private let targets: HarnessTargets
    private let webDrivers: WebDriverClients
    private let terminal: TerminalCapture?
    private let sleeper: any HarnessSleeper
    private let hooks: (any AppHookClient)?

    /// `hooks` nil: `testHook` steps report `needsHuman` (the app under test is not the hooks build).
    public init(
        system: any SystemActions, targets: HarnessTargets, webDrivers: WebDriverClients, terminal: TerminalCapture?,
        sleeper: any HarnessSleeper, hooks: (any AppHookClient)? = nil
    ) {
        self.system = system
        self.targets = targets
        self.webDrivers = webDrivers
        self.terminal = terminal
        self.sleeper = sleeper
        self.hooks = hooks
    }

    public func prepare(_ scenario: Scenario) async throws {
        guard scenario.targetBundleId.rawValue == HarnessTargets.testHostAlias else { return }
        try await system.resetTestHostFields(in: try resolve(scenario.targetBundleId))
    }

    /// A scenario that revoked the permission and did not restore it leaves the app failed open for the next
    /// one; restore it here (QA-R11 permission scenario).
    public func finish(_ scenario: Scenario) async {
        guard let hooks, ScenarioSchedule.hooks(of: scenario).last == .revokePermission else { return }
        try? await hooks.trigger(.restorePermission)
    }

    public func perform(_ step: Scenario.SetupStep, for scenario: Scenario) async throws {
        let target = try resolve(scenario.targetBundleId)
        let value = step.value.map(targets.expand)
        switch step.action {
        case .launch:
            let bundle = try value.flatMap(BundleKey.init(rawValue:)).map(resolve) ?? target
            if scenario.readback == .terminalCapture, bundle == target {
                try await startCapture(in: bundle)
            } else {
                try await system.launch(bundle)
            }
        case .openURL:
            let url = try required(value, step)
            if scenario.readback == .webdriver {
                let client = try webDrivers.client(for: target)
                if await !client.hasSession { try await client.startSession() }
                try await client.navigate(to: url)
            } else {
                try await system.open(url, in: target)
            }
        case .seedHistory: try await system.seedHistory(try required(value, step), in: target)
        case .focusField:
            let field = try required(value, step)
            if scenario.readback == .webdriver {
                try await webDrivers.client(for: target).click(selector: field)
            } else {
                try await system.focusField(identifier: field, in: target)
            }
        case .selectInputSource:
            guard let source = value.flatMap(InputSourceID.init(rawValue:)) else {
                throw HarnessSetupError.invalidValue(action: step.action.rawValue)
            }
            try await system.selectInputSource(source)
        case .setSecureInput: try await system.setSecureInput(try required(value, step) == "on", in: target)
        case .wait:
            guard let milliseconds = value.flatMap(UInt64.init) else {
                throw HarnessSetupError.invalidValue(action: step.action.rawValue)
            }
            try await sleeper.sleep(nanoseconds: milliseconds * 1_000_000)
        case .testHook: try await trigger(step)
        }
    }

    private func trigger(_ step: Scenario.SetupStep) async throws {
        guard let hook = ScenarioHookStep.of(step)?.hook else {
            throw HarnessSetupError.invalidValue(action: step.action.rawValue)
        }
        guard let hooks else {
            throw HumanReadbackRequired(
                reason: "test hook " + hook.rawValue + " needs the INTEGRATION_HOOKS test build of the app")
        }
        try await hooks.trigger(hook)
    }

    private func startCapture(in bundle: BundleKey) async throws {
        guard let terminal else { throw HarnessReadbackError.unavailable(.terminalCapture) }
        let script = terminal.captureFile.appendingPathExtension("zsh")
        try terminal.fileSystem.writeAtomically(
            Data(TerminalCaptureReadback.zshScript.utf8), to: script, permissions: .ownerOnlyFile)
        try await system.startTerminalCapture(in: bundle, script: script, captureFile: terminal.captureFile)
    }

    private func resolve(_ key: BundleKey) throws(HarnessSetupError) -> BundleKey {
        guard let resolved = targets.resolve(key) else { throw .unresolvedTarget(key.rawValue) }
        return resolved
    }

    private func required(_ value: String?, _ step: Scenario.SetupStep) throws(HarnessSetupError) -> String {
        guard let value, !value.isEmpty else { throw .invalidValue(action: step.action.rawValue) }
        return value
    }
}

/// Reads the text of an element by accessibility identifier (or the focused element) of an app. Runner only.
public protocol AXFieldReader: Sendable {
    func text(identifier: String?, in bundle: BundleKey) async throws -> String
}

/// One line from the tester; `nil` when no terminal is attached or input ended.
public protocol LineReader: Sendable {
    func readLine(prompt: String) -> String?
}

public enum HarnessReadbackError: Error, Sendable, Hashable {
    case unavailable(Scenario.Readback)
    case captureMissing(path: String)
}

/// Dispatches `currentText(of:)` by the scenario's readback kind.
public struct ReadbackRouter: ScenarioReadback {
    private let targets: HarnessTargets
    private let ax: (any AXFieldReader)?
    private let webDrivers: WebDriverClients
    private let terminal: TerminalCaptureReadback?
    private let human: HumanConfirmationReadback?

    public init(
        targets: HarnessTargets, ax: (any AXFieldReader)?, webDrivers: WebDriverClients,
        terminal: TerminalCaptureReadback?, human: HumanConfirmationReadback?
    ) {
        self.targets = targets
        self.ax = ax
        self.webDrivers = webDrivers
        self.terminal = terminal
        self.human = human
    }

    public func currentText(of scenario: Scenario) async throws -> String {
        guard let target = targets.resolve(scenario.targetBundleId) else {
            throw HarnessSetupError.unresolvedTarget(scenario.targetBundleId.rawValue)
        }
        let field = scenario.setup.last { $0.action == .focusField }?.value
        switch scenario.readback {
        case .ax:
            guard let ax else { throw HarnessReadbackError.unavailable(.ax) }
            return try await ax.text(identifier: field, in: target)
        case .webdriver:
            return try await webDrivers.client(for: target).fieldText(selector: field)
        case .terminalCapture:
            guard let terminal else { throw HarnessReadbackError.unavailable(.terminalCapture) }
            return try terminal.lastLine()
        case .human:
            guard let human else { throw HumanReadbackRequired() }
            return try human.confirm(scenario)
        }
    }
}

/// 13.2 terminal readback: a shell in the terminal under test writes each entered line to a capture file.
public struct TerminalCaptureReadback: Sendable {
    public static let maximumBytes = 1 << 20
    private let fileSystem: any FileSystem
    private let captureFile: URL

    public init(fileSystem: any FileSystem, captureFile: URL) {
        self.fileSystem = fileSystem
        self.captureFile = captureFile
    }

    /// Last non-empty line of the capture file.
    public func lastLine() throws -> String {
        guard fileSystem.fileExists(at: captureFile) else {
            throw HarnessReadbackError.captureMissing(path: captureFile.path)
        }
        let data = try fileSystem.readData(at: captureFile, maxBytes: Self.maximumBytes)
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// zsh script the terminal under test runs: line editing by zle (`vared`), each entered line appended to
    /// the capture file. Started by the setup on the runner (`zsh -f <script> <capture file>`).
    public static let zshScript = """
        #!/bin/zsh -f
        # SPDX-License-Identifier: GPL-3.0-or-later
        # compat-harness terminal capture (02-platform.md 13.2): writes every entered line to the file in $1.
        capture="$1"
        : > "$capture"
        while true; do
          line=""
          vared -p '> ' line || break
          print -r -- "$line" >> "$capture"
        done
        """
}

/// 13.2 human readback: shows the expected text and asks the tester to confirm or type what the field shows.
public struct HumanConfirmationReadback: Sendable {
    private let reader: any LineReader

    public init(reader: any LineReader) { self.reader = reader }

    public func confirm(_ scenario: Scenario) throws -> String {
        let expected = scenario.expect.text ?? ""
        let prompt =
            "[" + scenario.id + "] expected field text: \u{201C}" + expected
            + "\u{201D}. Press Return if it matches, otherwise type what the field shows: "
        guard let answer = reader.readLine(prompt: prompt) else { throw HumanReadbackRequired() }
        return answer.isEmpty ? expected : answer
    }
}
