import Foundation

/// Parses the two cookie formats a user can paste into Settings ("Paste cookies" sign-in fallback)
/// and serialises cookies for the `Cookie` header.
public enum CookieJar {
  public struct Parsed: Sendable, Equatable {
    public var cookies: [String: String]
    /// Earliest expiry found (Netscape format only).
    public var earliestExpiry: Date?

    public init(cookies: [String: String], earliestExpiry: Date?) {
      self.cookies = cookies
      self.earliestExpiry = earliestExpiry
    }
  }

  /// Accepts either a `Cookie:` header (`a=1; b=2`, optional `Cookie:` prefix) or a
  /// Netscape cookie file (7 tab-separated fields per line). Only youtube.com/google.com
  /// rows are kept from cookie files.
  public static func parse(_ text: String) -> Parsed {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("\t") {
      return parseNetscape(trimmed)
    }
    return Parsed(cookies: parseHeader(trimmed), earliestExpiry: nil)
  }

  public static func parseHeader(_ text: String) -> [String: String] {
    var body = Substring(text)
    if body.lowercased().hasPrefix("cookie:") { body = body.dropFirst("cookie:".count) }
    var result: [String: String] = [:]
    for part in body.split(separator: ";") {
      guard let eq = part.firstIndex(of: "=") else { continue }
      let name = part[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { result[name] = value }
    }
    return result
  }

  static func parseNetscape(_ text: String) -> Parsed {
    var cookies: [String: String] = [:]
    var earliest: Date?
    for rawLine in text.split(whereSeparator: \.isNewline) {
      var line = Substring(rawLine)
      if line.hasPrefix("#HttpOnly_") { line = line.dropFirst("#HttpOnly_".count) }
      else if line.hasPrefix("#") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 7 else { continue }
      let domain = fields[0].lowercased()
      guard domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com") else { continue }
      let name = String(fields[5])
      let value = fields[6...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
      // youtube.com rows win over google.com rows with the same name.
      if cookies[name] == nil || domain.hasSuffix("youtube.com") { cookies[name] = value }
      if let expiry = TimeInterval(fields[4]), expiry > 0 {
        let date = Date(timeIntervalSince1970: expiry)
        earliest = earliest.map { min($0, date) } ?? date
      }
    }
    return Parsed(cookies: cookies, earliestExpiry: earliest)
  }

  /// Deterministic `Cookie` header value.
  public static func headerValue(_ cookies: [String: String]) -> String {
    cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
  }
}
