import Foundation

enum JSONSupport {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func requiredObject(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value = object(value) else {
            throw ModuleCompilationError.invalidValue(path: path, expected: "an object")
        }
        return value
    }

    static func requiredArray(_ value: Any?, path: String) throws -> [Any] {
        guard let value = array(value) else {
            throw ModuleCompilationError.invalidValue(path: path, expected: "an array")
        }
        return value
    }

    static func requiredString(_ value: Any?, path: String) throws -> String {
        guard let value = string(value), !value.isEmpty else {
            throw ModuleCompilationError.missingValue(path: path)
        }
        return value
    }

    static func requiredInteger(_ value: Any?, path: String) throws -> Int {
        guard let value = integer(value) else {
            throw ModuleCompilationError.invalidValue(path: path, expected: "an integer")
        }
        return value
    }

    static func jsonString(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull), isMeaningful(value) else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ModuleCompilationError.invalidValue(path: "/", expected: "JSON-compatible content")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func plainText(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            return array.map(plainText).filter { !$0.isEmpty }.joined(separator: " ")
        }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String { return text }
            if let content = object["content"] { return plainText(content) }
        }
        return ""
    }

    static func firstValue(in object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }

    static func isMeaningful(_ value: Any) -> Bool {
        if let string = value as? String { return !string.isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return !(value is NSNull)
    }
}
