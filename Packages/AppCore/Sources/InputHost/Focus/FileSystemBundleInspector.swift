// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production `BundleInspector` (PLT-R510): read-only, bounded FileManager listing of an app bundle on the ax
// thread. Results are cached by the focus tracker, so each bundle version is inspected once.

public import AppModel
public import CompatRules
public import Foundation

public struct FileSystemBundleInspector: BundleInspector {
    /// Depth under `Contents/Frameworks` searched for nested helper apps (Chromium keeps them in
    /// `<Name> Framework.framework/Versions/<V>/Helpers/`).
    public static let helperSearchDepth = 5
    /// Upper bound on directory entries visited by one bounded search.
    public static let maximumEntries = 20_000

    public init() {}

    public func frameworkNames(in bundle: URL) -> [String] {
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.sorted()
    }

    public func helperAppNames(in bundle: URL) -> [String] {
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        var names: [String] = []
        visit(frameworks, maxDepth: Self.helperSearchDepth) { url in
            guard url.pathExtension == "app" else { return .continue }
            names.append(url.lastPathComponent)
            return .skipDescendants
        }
        return names.sorted()
    }

    public func containsFile(named name: String, in bundle: URL, maxDepth: Int) -> Bool {
        var found = false
        visit(bundle.appendingPathComponent("Contents", isDirectory: true), maxDepth: maxDepth) { url in
            guard url.lastPathComponent == name else { return .continue }
            found = true
            return .stop
        }
        return found
    }

    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist.compactMapValues(Self.jsonValue)
    }

    enum Visit { case `continue`, skipDescendants, stop }

    private func visit(_ root: URL, maxDepth: Int, _ body: (URL) -> Visit) {
        guard maxDepth > 0,
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= Self.maximumEntries else { return }
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            switch body(url) {
            case .continue: break
            case .skipDescendants: enumerator.skipDescendants()
            case .stop: return
            }
        }
    }

    static func jsonValue(_ value: Any) -> JSONValue? {
        switch value {
        case let string as String: return .string(string)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]: return .array(array.compactMap(jsonValue))
        case let dictionary as [String: Any]: return .object(dictionary.compactMapValues(jsonValue))
        default: return nil
        }
    }
}
