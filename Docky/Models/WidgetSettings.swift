//
//  WidgetSettings.swift
//  Docky
//

import Foundation

nonisolated enum WidgetSettingValue:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case stringList([String])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringListValue: [String]? {
        if case .stringList(let value) = self { return value }
        return nil
    }

    /// Cocoa primitive so it can cross the @objc boundary into a plugin's `makeView(configuration:)`.
    var cocoaValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .stringList(let value): value
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode("number", forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode("bool", forKey: .type)
            try container.encode(value, forKey: .value)
        case .stringList(let value):
            try container.encode("stringList", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "number":
            self = .number(try container.decode(Double.self, forKey: .value))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case "stringList":
            self = .stringList(try container.decode([String].self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown WidgetSettingValue type: \(type)"
            )
        }
    }
}

typealias WidgetSettings = [String: WidgetSettingValue]

extension Dictionary where Key == String, Value == WidgetSettingValue {
    var asCocoaConfiguration: [String: Any] {
        mapValues(\.cocoaValue)
    }

    func string(_ key: String) -> String? { self[key]?.stringValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func stringList(_ key: String) -> [String]? { self[key]?.stringListValue }
}
