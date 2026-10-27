import Foundation

public struct GoogleSession: Codable, Sendable, Equatable {
  public var cookies: [String: String]
  public var expiresAt: Date
  public var name: String?
  public var avatarURL: URL?

  public init(cookies: [String: String], expiresAt: Date, name: String? = nil, avatarURL: URL? = nil) {
    self.cookies = cookies
    self.expiresAt = expiresAt
    self.name = name
    self.avatarURL = avatarURL
  }

  /// Cookies captured from a sign-in are usable only if they carry a SAPISID-family secret.
  public var hasAuthCookie: Bool {
    cookies["SAPISID"] != nil || cookies["__Secure-3PAPISID"] != nil
  }

  /// Names whose `.google.com` copies are accepted when capturing cookies.
  public static let googleDomainCookieNames: Set<String> = ["SID", "HSID", "SSID", "APISID", "SAPISID"]
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

  public func current() async -> GoogleSession? { session }

  public func save(_ s: GoogleSession?) async { session = s }
}
