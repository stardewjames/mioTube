import Foundation

/// YouTube's cookie-bound `Authorization` header.
public enum SapisidAuth {
  /// Each available SAPISID-family secret signs the request origin independently.
  /// The optional user-session binding is the `u` variant used by YouTube web accounts.
  public static func header(
    cookies: [String: String],
    origin: String = "https://www.youtube.com",
    timestamp: Int = .init(Date().timeIntervalSince1970),
    userSessionID: String? = nil
  ) -> String? {
    let primary = cookies["SAPISID"].flatMap { $0.isEmpty ? nil : $0 }
      ?? cookies["__Secure-3PAPISID"].flatMap { $0.isEmpty ? nil : $0 }
    let secrets = [
      ("SAPISIDHASH", primary),
      ("SAPISID1PHASH", cookies["__Secure-1PAPISID"]),
      ("SAPISID3PHASH", cookies["__Secure-3PAPISID"]),
    ]
    let parts = secrets.compactMap { scheme, secret -> String? in
      guard let secret, !secret.isEmpty else { return nil }
      return "\(scheme) \(hash(timestamp, secret, origin, userSessionID: userSessionID))"
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  static func hash(_ timestamp: Int, _ secret: String, _ origin: String, userSessionID: String? = nil) -> String {
    if let userSessionID, !userSessionID.isEmpty {
      return "\(timestamp)_\(sha1Hex("\(userSessionID) \(timestamp) \(secret) \(origin)"))_u"
    }
    return "\(timestamp)_\(sha1Hex("\(timestamp) \(secret) \(origin)"))"
  }
}
