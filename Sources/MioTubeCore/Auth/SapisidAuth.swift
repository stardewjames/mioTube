import Foundation

/// YouTube's cookie-bound `Authorization` header.
public enum SapisidAuth {
  /// `SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>`, followed by the `SAPISID1PHASH` /
  /// `SAPISID3PHASH` variants when the matching `__Secure-*PAPISID` cookies exist (what
  /// youtube.com itself sends). Nil when no SAPISID-family cookie is present.
  public static func header(
    cookies: [String: String],
    origin: String = "https://www.youtube.com",
    timestamp: Int = .init(Date().timeIntervalSince1970)
  ) -> String? {
    guard let sapisid = cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"] else { return nil }
    var parts = ["SAPISIDHASH \(hash(timestamp, sapisid, origin))"]
    if let first = cookies["__Secure-1PAPISID"] {
      parts.append("SAPISID1PHASH \(hash(timestamp, first, origin))")
    }
    if let third = cookies["__Secure-3PAPISID"], cookies["SAPISID"] != nil || cookies["__Secure-1PAPISID"] != nil {
      parts.append("SAPISID3PHASH \(hash(timestamp, third, origin))")
    }
    return parts.joined(separator: " ")
  }

  static func hash(_ timestamp: Int, _ secret: String, _ origin: String) -> String {
    "\(timestamp)_\(sha1Hex("\(timestamp) \(secret) \(origin)"))"
  }
}
