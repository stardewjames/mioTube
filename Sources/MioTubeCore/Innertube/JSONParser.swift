import Foundation

/// Byte-level JSON parser producing `JSONValue` directly. InnerTube responses are 0.1–1.5 MB;
/// the `Codable` path (`try?` per type per node) is an order of magnitude slower.
struct JSONParser {
  private let bytes: UnsafeBufferPointer<UInt8>
  private var index = 0
  private var depth = 0
  private static let maxDepth = 512

  enum Failure: Error, CustomStringConvertible {
    case unexpected(at: Int)
    case tooDeep

    var description: String {
      switch self {
      case .unexpected(let at): "invalid JSON at byte \(at)"
      case .tooDeep: "JSON nesting too deep"
      }
    }
  }

  static func parse(_ data: Data) throws -> JSONValue {
    try data.withUnsafeBytes { raw in
      var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
      parser.skipBOM()
      let value = try parser.parseValue()
      parser.skipWhitespace()
      guard parser.index == parser.bytes.count else { throw Failure.unexpected(at: parser.index) }
      return value
    }
  }

  private init(bytes: UnsafeBufferPointer<UInt8>) {
    self.bytes = bytes
  }

  private mutating func skipBOM() {
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
  }

  private mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  private mutating func parseValue() throws -> JSONValue {
    skipWhitespace()
    guard index < bytes.count else { throw Failure.unexpected(at: index) }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try parseObject()
    case UInt8(ascii: "["): return try parseArray()
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    default: return .number(try parseNumber())
    }
  }

  private mutating func expect(_ literal: StaticString) throws {
    let count = literal.utf8CodeUnitCount
    guard index + count <= bytes.count else { throw Failure.unexpected(at: index) }
    let start = literal.utf8Start
    for offset in 0..<count where bytes[index + offset] != start[offset] {
      throw Failure.unexpected(at: index + offset)
    }
    index += count
  }

  private mutating func parseObject() throws -> JSONValue {
    depth += 1
    defer { depth -= 1 }
    guard depth <= Self.maxDepth else { throw Failure.tooDeep }
    index += 1
    var object: [String: JSONValue] = [:]
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      index += 1
      return .object(object)
    }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure.unexpected(at: index) }
      let key = try parseString()
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure.unexpected(at: index) }
      index += 1
      object[key] = try parseValue()
      skipWhitespace()
      guard index < bytes.count else { throw Failure.unexpected(at: index) }
      if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
      if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
      throw Failure.unexpected(at: index)
    }
  }

  private mutating func parseArray() throws -> JSONValue {
    depth += 1
    defer { depth -= 1 }
    guard depth <= Self.maxDepth else { throw Failure.tooDeep }
    index += 1
    var array: [JSONValue] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      index += 1
      return .array(array)
    }
    while true {
      array.append(try parseValue())
      skipWhitespace()
      guard index < bytes.count else { throw Failure.unexpected(at: index) }
      if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
      if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
      throw Failure.unexpected(at: index)
    }
  }

  private mutating func parseString() throws -> String {
    index += 1 // opening quote
    let start = index
    // Fast path: no escapes.
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "\"") {
        let string = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        index += 1
        return string
      }
      if byte == UInt8(ascii: "\\") { break }
      index += 1
    }
    var scalars: [UInt8] = Array(bytes[start..<index])
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "\"") {
        index += 1
        return String(decoding: scalars, as: UTF8.self)
      }
      if byte != UInt8(ascii: "\\") {
        scalars.append(byte)
        index += 1
        continue
      }
      index += 1
      guard index < bytes.count else { throw Failure.unexpected(at: index) }
      let escape = bytes[index]
      index += 1
      switch escape {
      case UInt8(ascii: "\""): scalars.append(0x22)
      case UInt8(ascii: "\\"): scalars.append(0x5C)
      case UInt8(ascii: "/"): scalars.append(0x2F)
      case UInt8(ascii: "b"): scalars.append(0x08)
      case UInt8(ascii: "f"): scalars.append(0x0C)
      case UInt8(ascii: "n"): scalars.append(0x0A)
      case UInt8(ascii: "r"): scalars.append(0x0D)
      case UInt8(ascii: "t"): scalars.append(0x09)
      case UInt8(ascii: "u"):
        var code = try parseHex4()
        if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
          index += 2
          let low = try parseHex4()
          if (0xDC00...0xDFFF).contains(low) {
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
          } else {
            code = 0xFFFD
          }
        }
        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
        scalars.append(contentsOf: Array(String(Character(scalar)).utf8))
      default:
        throw Failure.unexpected(at: index - 1)
      }
    }
    throw Failure.unexpected(at: index)
  }

  private mutating func parseHex4() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw Failure.unexpected(at: index) }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      let digit: UInt32
      switch byte {
      case 0x30...0x39: digit = UInt32(byte - 0x30)
      case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
      case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
      default: throw Failure.unexpected(at: index)
      }
      value = value << 4 | digit
      index += 1
    }
    return value
  }

  private mutating func parseNumber() throws -> Double {
    let start = index
    while index < bytes.count {
      switch bytes[index] {
      case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
           UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
        index += 1
      default:
        guard index > start else { throw Failure.unexpected(at: index) }
        return try number(start)
      }
    }
    return try number(start)
  }

  private func number(_ start: Int) throws -> Double {
    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
    guard let value = Double(text) else { throw Failure.unexpected(at: start) }
    return value
  }
}
