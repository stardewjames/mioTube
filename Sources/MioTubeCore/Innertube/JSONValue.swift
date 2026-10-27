import Foundation

/// Lossless JSON tree. InnerTube responses are huge and schema-less, so parsers navigate
/// them by path instead of decoding into fixed structs.
public enum JSONValue: Sendable, Hashable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension JSONValue {
  public static func decode(_ data: Data) throws -> JSONValue {
    do {
      return try JSONParser.parse(data)
    } catch {
      throw MioTubeError.decoding(String(describing: error))
    }
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Path lookup. Components address object keys; numeric components also index arrays.
  public subscript(_ path: String...) -> JSONValue? {
    self[path: path]
  }

  public subscript(path path: [String]) -> JSONValue? {
    var current: JSONValue? = self
    for component in path {
      switch current {
      case .object(let object)?:
        current = object[component]
      case .array(let array)?:
        guard let index = Int(component), array.indices.contains(index) else { return nil }
        current = array[index]
      default:
        return nil
      }
    }
    return current
  }

  public var object: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var double: Double? {
    switch self {
    case .number(let value): value
    case .string(let value): Double(value)
    default: nil
    }
  }

  public var int: Int? {
    switch self {
    case .number(let value): Int(exactly: value.rounded(.towardZero))
    case .string(let value): Int(value)
    default: nil
    }
  }

  public var bool: Bool? {
    switch self {
    case .bool(let value): value
    case .string(let value): value == "true" ? true : (value == "false" ? false : nil)
    default: nil
    }
  }

  /// YouTube text in any of its three shapes: `{simpleText}`, `{runs:[{text}]}`, `{content}`,
  /// or a bare string.
  public var text: String? {
    if let string { return string }
    if let simple = self["simpleText"]?.string { return simple }
    if let runs = self["runs"]?.array {
      let joined = runs.compactMap { $0["text"]?.string }.joined()
      return joined.isEmpty ? nil : joined
    }
    if let content = self["content"]?.string { return content }
    return nil
  }

  /// Highest-resolution URL from `{thumbnails:[{url,width}]}` or `{sources:[{url,width}]}`,
  /// also looking one level into `image`/`thumbnail`. Protocol-relative URLs become https.
  public func firstThumbnailURL() -> URL? {
    for key in ["thumbnails", "sources"] {
      if let list = self[key]?.array, !list.isEmpty {
        let best = list.max { ($0["width"]?.double ?? 0) < ($1["width"]?.double ?? 0) } ?? list[list.count - 1]
        if let raw = best["url"]?.string { return Self.normalizedURL(raw) }
      }
    }
    for key in ["image", "thumbnail"] {
      if let nested = self[key], let url = nested.firstThumbnailURL() { return url }
    }
    return nil
  }

  static func normalizedURL(_ raw: String) -> URL? {
    if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
    return URL(string: raw)
  }

  /// Removes the value at `path`. No-op when the path does not exist.
  public mutating func remove(_ path: String...) {
    remove(path: path[...])
  }

  private mutating func remove(path: ArraySlice<String>) {
    guard let head = path.first else { return }
    let rest = path.dropFirst()
    switch self {
    case .object(var object):
      if rest.isEmpty {
        object.removeValue(forKey: head)
      } else if var child = object[head] {
        child.remove(path: rest)
        object[head] = child
      }
      self = .object(object)
    case .array(var array):
      guard let index = Int(head), array.indices.contains(index) else { return }
      if rest.isEmpty {
        array.remove(at: index)
      } else {
        array[index].remove(path: rest)
      }
      self = .array(array)
    default:
      return
    }
  }

  /// Depth-first search for the first value stored under `key`.
  public func first(key: String) -> JSONValue? {
    switch self {
    case .object(let object):
      if let hit = object[key] { return hit }
      for value in object.values {
        if let hit = value.first(key: key) { return hit }
      }
      return nil
    case .array(let array):
      for value in array {
        if let hit = value.first(key: key) { return hit }
      }
      return nil
    default:
      return nil
    }
  }

  /// Merges object members of `other` into `self` (shallow). Non-objects are left unchanged.
  public func merging(_ other: [String: JSONValue]) -> JSONValue {
    guard case .object(var object) = self else { return self }
    for (key, value) in other { object[key] = value }
    return .object(object)
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}
