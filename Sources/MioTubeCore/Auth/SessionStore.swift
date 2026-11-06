import Foundation

public struct GoogleSession: Codable, Sendable, Hashable {
  public var cookies: [String: String]
  public var expiresAt: Date
  public var name: String?
  public var avatarURL: URL?
  /// Account/channel routing captured from the authenticated YouTube bootstrap.
  public var accountIndex: Int?
  public var delegatedSessionID: String?
  public var userSessionID: String?

  public init(
    cookies: [String: String], expiresAt: Date, name: String? = nil, avatarURL: URL? = nil,
    accountIndex: Int? = nil, delegatedSessionID: String? = nil, userSessionID: String? = nil
  ) {
    self.cookies = cookies
    self.expiresAt = expiresAt
    self.name = name
    self.avatarURL = avatarURL
    self.accountIndex = accountIndex
    self.delegatedSessionID = delegatedSessionID
    self.userSessionID = userSessionID
  }

  /// Cookies captured from a sign-in are usable only if they carry a SAPISID-family secret.
  public var hasAuthCookie: Bool {
    ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"].contains {
      cookies[$0]?.isEmpty == false
    }
  }

  public func hasSameIdentity(as other: GoogleSession) -> Bool {
    cookies == other.cookies && accountIndex == other.accountIndex
      && delegatedSessionID == other.delegatedSessionID && userSessionID == other.userSessionID
  }

  /// Names whose `.google.com` copies are accepted when capturing cookies.
  public static let googleDomainCookieNames: Set<String> = ["SID", "HSID", "SSID", "APISID", "SAPISID"]

  /// Cookies that carry (or expire with) the Google session. Only these decide when a stored
  /// session is considered expired; analytics/consent cookies expire much sooner and must not
  /// force a re-sign-in.
  public static let authCookieNames: Set<String> = [
    "SID", "HSID", "SSID", "APISID", "SAPISID", "__Secure-1PSID", "__Secure-3PSID",
    "__Secure-1PAPISID", "__Secure-3PAPISID", "LOGIN_INFO",
  ]

  /// Cookie domains may start with a dot; suffix lookalikes must never import credentials.
  public static func matchesDomain(_ domain: String, root: String) -> Bool {
    let host = (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
    let root = root.lowercased()
    return host == root || host.hasSuffix("." + root)
  }
}

public protocol SessionProviding: Sendable {
  func current() async -> GoogleSession?
}

public protocol SessionStore: SessionProviding {
  func save(_ s: GoogleSession?) async
}

/// Process-lifetime store (tests, previews, and the "signed out" default).
public actor InMemorySessionStore: SessionStore {
  private var session: GoogleSession?

  public init(_ session: GoogleSession? = nil) {
    self.session = session
  }

  public func current() async -> GoogleSession? {
    guard let session, session.expiresAt > Date() else { return nil }
    return session
  }

  public func save(_ s: GoogleSession?) async { session = s }
}
