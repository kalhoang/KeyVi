// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal W3C WebDriver client for browser page readback (13.2: `safaridriver`, `chromedriver`). Talks only
// to driver endpoints on the loopback interface: the ones given on the command line (`--webdriver
// <bundle>=<url>`), and for every other webdriver target the chromedriver default `http://127.0.0.1:9515`, so
// the agreed CI command line (ADR 0502, scripts/run-integration.sh) needs no extra flag.
// The transport is a protocol: the live one is URLSession (CompatHarness/Live), tests use a fake.
// VERIFY on the runner: Safari's automation window blocks physical input while a session is active, which
// may rule out webdriver readback for Safari scenarios that type through the harness keyboard driver.

public import AppModel
public import Foundation

public protocol HTTPTransport: Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> (status: Int, body: Data)
}

public enum WebDriverError: Error, Sendable, Hashable {
    case noEndpoint(target: String)
    case nonLoopbackEndpoint(String)
    case http(status: Int)
    case malformedResponse
    case noSession(target: String)
}

/// One endpoint, one session. Sessions are created by the setup step `openURL` and reused by the readback.
public actor WebDriverClient {
    /// W3C element reference key (WebDriver spec, "Elements").
    static let elementKey = "element-6066-11e4-a52e-4f735466cecf"

    private let transport: any HTTPTransport
    private let endpoint: URL
    private var sessionID: String?

    public init(transport: any HTTPTransport, endpoint: URL) throws(WebDriverError) {
        guard let host = endpoint.host, ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw .nonLoopbackEndpoint(endpoint.absoluteString)
        }
        self.transport = transport
        self.endpoint = endpoint
    }

    public var hasSession: Bool { sessionID != nil }

    public func startSession() async throws {
        let body: JSONValue = .object(["capabilities": .object(["alwaysMatch": .object([:])])])
        let value = try await call("POST", "session", body)
        guard let id = value["sessionId"]?.stringValue else { throw WebDriverError.malformedResponse }
        sessionID = id
    }

    public func navigate(to url: String) async throws {
        _ = try await call("POST", try sessionPath("url"), .object(["url": .string(url)]))
    }

    /// Clicks the first element matching `selector` (focuses a page field).
    public func click(selector: String) async throws {
        let found = try await call(
            "POST", try sessionPath("element"), .object(["using": .string("css selector"), "value": .string(selector)]))
        guard let element = found[Self.elementKey]?.stringValue else { throw WebDriverError.malformedResponse }
        _ = try await call("POST", try sessionPath("element/" + element + "/click"), .object([:]))
    }

    /// Value of a form field or text of an editable element; the focused element when `selector` is nil.
    public func fieldText(selector: String?) async throws -> String {
        let script = """
            const el = arguments[0] ? document.querySelector(arguments[0]) : document.activeElement;
            if (!el) { return null; }
            return (el.value !== undefined) ? el.value : el.innerText;
            """
        let argument: JSONValue = selector.map(JSONValue.string) ?? .null
        let value = try await call(
            "POST", try sessionPath("execute/sync"), .object(["script": .string(script), "args": .array([argument])]))
        guard let text = value.stringValue else { throw WebDriverError.malformedResponse }
        return text
    }

    private func sessionPath(_ suffix: String) throws(WebDriverError) -> String {
        guard let sessionID else { throw .noSession(target: endpoint.absoluteString) }
        return "session/" + sessionID + "/" + suffix
    }

    private func call(_ method: String, _ path: String, _ body: JSONValue) async throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(body)
        let response = try await transport.send(
            method: method, url: endpoint.appendingPathComponent(path), body: encoded)
        guard (200..<300).contains(response.status) else { throw WebDriverError.http(status: response.status) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.body)["value"] else {
            throw WebDriverError.malformedResponse
        }
        return value
    }
}

/// WebDriver clients keyed by the real bundle ID of the browser a scenario targets, plus one optional fallback
/// client shared by every target without its own endpoint.
public struct WebDriverClients: Sendable {
    /// `chromedriver`'s default port on the loopback interface (chromedriver documentation).
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:9515")!

    private let clients: [BundleKey: WebDriverClient]
    private let fallback: WebDriverClient?

    public init(clients: [BundleKey: WebDriverClient], fallback: WebDriverClient? = nil) {
        self.clients = clients
        self.fallback = fallback
    }

    /// Builds clients from `--webdriver <bundle>=<url>` options and the fallback endpoint.
    public init(endpoints: [BundleKey: URL], transport: any HTTPTransport, fallback: URL? = nil)
        throws(WebDriverError)
    {
        var clients: [BundleKey: WebDriverClient] = [:]
        for (bundle, url) in endpoints { clients[bundle] = try WebDriverClient(transport: transport, endpoint: url) }
        self.clients = clients
        self.fallback = try fallback.map { url throws(WebDriverError) in
            try WebDriverClient(transport: transport, endpoint: url)
        }
    }

    public func client(for bundle: BundleKey) throws(WebDriverError) -> WebDriverClient {
        guard let client = clients[bundle] ?? fallback else { throw .noEndpoint(target: bundle.rawValue) }
        return client
    }
}
