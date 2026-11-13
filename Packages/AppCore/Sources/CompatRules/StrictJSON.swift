// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Strict decoding for the compatibility files (PLT-R503 "validated at load"). Swift's synthesized Decodable
// ignores unknown keys; the JSON Schemas say `additionalProperties: false`. The decoded value is re-encoded and
// every key of the raw document must survive the round trip, so a misspelt key is rejected instead of being
// silently dropped. Error paths name keys and indices only, never values.

import AppModel
import Foundation

enum StrictJSON {
    static func decode<T: Codable>(
        _ type: T.Type, from data: Data, allowedRootKeys: Set<String>
    ) throws(RulesValidationError) -> T {
        let raw: JSONValue
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .decoding(path: "$", reason: "not valid JSON")
        }
        return try decode(type, raw: raw, data: data, allowedRootKeys: allowedRootKeys)
    }

    static func decode<T: Codable>(
        _ type: T.Type, from raw: JSONValue, allowedRootKeys: Set<String>
    ) throws(RulesValidationError) -> T {
        let data: Data
        do {
            data = try JSONEncoder().encode(raw)
        } catch {
            throw .decoding(path: "$", reason: "not encodable as JSON")
        }
        return try decode(type, raw: raw, data: data, allowedRootKeys: allowedRootKeys)
    }

    private static func decode<T: Codable>(
        _ type: T.Type, raw: JSONValue, data: Data, allowedRootKeys: Set<String>
    ) throws(RulesValidationError) -> T {
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw describe(error)
        } catch {
            throw .decoding(path: "$", reason: "unreadable")
        }
        let echoed: JSONValue
        do {
            echoed = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        } catch {
            throw .decoding(path: "$", reason: "not encodable as JSON")
        }
        if let path = unknownKeyPath(raw: raw, echoed: echoed, path: "$", allowedRootKeys: allowedRootKeys) {
            throw .decoding(path: path, reason: "unknown key or null value")
        }
        return value
    }

    /// First key present in `raw` but missing after the decode/encode round trip.
    static func unknownKeyPath(
        raw: JSONValue, echoed: JSONValue, path: String, allowedRootKeys: Set<String>
    ) -> String? {
        switch (raw, echoed) {
        case (.object(let rawObject), .object(let echoedObject)):
            for key in rawObject.keys.sorted() {
                guard let rawChild = rawObject[key] else { continue }
                guard let echoedChild = echoedObject[key] else {
                    if path == "$" && allowedRootKeys.contains(key) { continue }
                    return path + "." + key
                }
                let childPath = path + "." + key
                if let found = unknownKeyPath(raw: rawChild, echoed: echoedChild, path: childPath, allowedRootKeys: [])
                {
                    return found
                }
            }
            return nil
        case (.array(let rawItems), .array(let echoedItems)):
            for (index, pair) in zip(rawItems, echoedItems).enumerated() {
                let childPath = path + "[" + String(index) + "]"
                if let found = unknownKeyPath(raw: pair.0, echoed: pair.1, path: childPath, allowedRootKeys: []) {
                    return found
                }
            }
            return nil
        default:
            return nil
        }
    }

    static func describe(_ error: DecodingError) -> RulesValidationError {
        switch error {
        case .keyNotFound(let key, let context):
            return .decoding(path: render(context.codingPath + [key]), reason: "missing required key")
        case .typeMismatch(_, let context):
            return .decoding(path: render(context.codingPath), reason: "wrong type")
        case .valueNotFound(_, let context):
            return .decoding(path: render(context.codingPath), reason: "missing value")
        case .dataCorrupted(let context):
            return .decoding(path: render(context.codingPath), reason: "invalid value")
        @unknown default:
            return .decoding(path: "$", reason: "unreadable")
        }
    }

    static func render(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("$") { path, key in
            if let index = key.intValue { return path + "[" + String(index) + "]" }
            return path + "." + key.stringValue
        }
    }
}
