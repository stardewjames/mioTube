import Foundation

/// A compatibility identity sourced from maintained InnerTube implementations, not a claim
/// of full native-client emulation. WEB may use its live bootstrap version; other pins are fallbacks.
public struct ClientProfile: Sendable, Codable, Identifiable, Hashable {
  public let id: String
  public let clientName: String
  public let clientVersion: String
  /// Numeric value for `X-YouTube-Client-Name`.
  public let clientNameHeader: Int
  public let userAgent: String?
  public let supportsCookies: Bool
  /// Allows consuming an HLS URL when the response actually supplies one.
  public let supportsHLS: Bool
  /// Skip this profile for native playback. A false value still requires checking each URL
  /// for signature/n-param transforms; it does not assert that every returned format is usable.
  public let requiresJSPlayer: Bool
  public let extraContext: [String: JSONValue]?

  /// `gzip(gfe)` describes the client context, not an HTTP browser user-agent token.
  public var httpUserAgent: String? {
    guard let userAgent else { return nil }
    let suffix = ",gzip(gfe)"
    return userAgent.hasSuffix(suffix) ? String(userAgent.dropLast(suffix.count)) : userAgent
  }

  public init(
    id: String, clientName: String, clientVersion: String, clientNameHeader: Int, userAgent: String?,
    supportsCookies: Bool, supportsHLS: Bool, requiresJSPlayer: Bool, extraContext: [String: JSONValue]? = nil
  ) {
    self.id = id
    self.clientName = clientName
    self.clientVersion = clientVersion
    self.clientNameHeader = clientNameHeader
    self.userAgent = userAgent
    self.supportsCookies = supportsCookies
    self.supportsHLS = supportsHLS
    self.requiresJSPlayer = requiresJSPlayer
    self.extraContext = extraContext
  }
}

public struct ProfileCatalog: Sendable, Codable, Hashable {
  public let apiKey: String
  public let metadataProfile: String
  public let playbackOrder: [String]
  public let profiles: [ClientProfile]

  public init(apiKey: String, metadataProfile: String, playbackOrder: [String], profiles: [ClientProfile]) {
    self.apiKey = apiKey
    self.metadataProfile = metadataProfile
    self.playbackOrder = playbackOrder
    self.profiles = profiles
  }

  public func profile(_ id: String) -> ClientProfile? {
    profiles.first { $0.id == id }
  }

  public var metadata: ClientProfile {
    guard let profile = profile(metadataProfile) else {
      preconditionFailure("ClientProfiles.json: metadataProfile '\(metadataProfile)' missing")
    }
    return profile
  }

  /// The catalog shipped in the package bundle.
  public static func bundled() throws -> ProfileCatalog {
    guard let url = Bundle.module.url(forResource: "ClientProfiles", withExtension: "json") else {
      throw MioTubeError.decoding("ClientProfiles.json missing from bundle")
    }
    return try decode(Data(contentsOf: url))
  }

  public static func decode(_ data: Data) throws -> ProfileCatalog {
    do {
      return try JSONDecoder().decode(ProfileCatalog.self, from: data)
    } catch {
      throw MioTubeError.decoding("ClientProfiles.json: \(error)")
    }
  }
}
