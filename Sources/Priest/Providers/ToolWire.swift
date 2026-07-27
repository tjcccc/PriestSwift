import Foundation

// Shared tool wire helpers for the built-in providers (spec 2.4.0).

func jsonValueObject(fromFoundation value: Any?) -> [String: JSONValue] {
    guard let dict = value as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: dict),
          let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
          case let .object(map) = decoded else { return [:] }
    return map
}

func jsonValue(fromFoundation value: Any?) -> JSONValue? {
    guard let value,
          JSONSerialization.isValidJSONObject(["value": value]),
          let data = try? JSONSerialization.data(withJSONObject: ["value": value]),
          let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return nil }
    return decoded["value"]
}

func foundationObject(from arguments: [String: JSONValue]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in arguments {
        out[key] = value.toFoundation()
    }
    return out
}

func argumentsJSONString(_ arguments: [String: JSONValue]) -> String {
    let object = foundationObject(from: arguments)
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
