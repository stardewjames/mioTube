import Foundation

/// Parses the two cookie formats a user can paste into Settings ("Paste cookies" sign-in fallback)
/// and serialises cookies for the `Cookie` header.
public enum CookieJar {
  public struct Parsed: Sendable, Equatable {
    public var cookies: [String: String]
    /// Earliest expiry among the effective auth cookies (Netscape format only).
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

  /// Netscape rows. Echoing a whole browser jar means short-lived cookies (`VISITOR_INFO1_LIVE`,
  /// `PREF`, …) would otherwise mark the session expired days before the Google login actually
  /// lapses, so only auth-cookie expiries are reported.
  static func parseNetscape(_ text: String) -> Parsed {
    var selected: [String: (value: String, expiry: Date?)] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      var line = Substring(rawLine)
      if line.hasPrefix("#HttpOnly_") { line = line.dropFirst("#HttpOnly_".count) }
      else if line.hasPrefix("#") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 7 else { continue }
      let domain = fields[0].lowercased()
      let youtube = GoogleSession.matchesDomain(domain, root: "youtube.com")
      let google = GoogleSession.matchesDomain(domain, root: "google.com")
      let name = String(fields[5])
      guard youtube || (google && GoogleSession.googleDomainCookieNames.contains(name)) else { continue }
      // This jar is sent to www.youtube.com at /youtubei/...; do not flatten cookies
      // scoped to another YouTube host or a different path into this request.
      let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
      if youtube {
        let includesSubdomains = fields[1].uppercased() == "TRUE"
        guard host == "www.youtube.com" || (host == "youtube.com" && includesSubdomains) else { continue }
        guard fields[2] == "/" else { continue }
      }
      let value = fields[6...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
      let expiry = TimeInterval(fields[4]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
      // YouTube wins regardless of row order; a discarded Google copy cannot expire it.
      if selected[name] == nil || youtube {
        selected[name] = (value, expiry)
      }
    }
    let cookies = selected.mapValues(\.value)
    let earliest = selected.compactMap { name, row in
      GoogleSession.authCookieNames.contains(name) ? row.expiry : nil
    }.min()
    return Parsed(cookies: cookies, earliestExpiry: earliest)
  }

  /// Deterministic `Cookie` header value.
  public static func headerValue(_ cookies: [String: String]) -> String {
    cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
  }
}
