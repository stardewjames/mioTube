import Foundation

/// One InnerTube client identity. All values are data (ClientProfiles.json) so YouTube drift
/// is fixed without touching code.
public struct ClientProfile: Sendable, Codable, Identifiable, Hashable {
  public let id: String
  public let clientName: String
  public let clientVersion: String
  /// Numeric value for `X-YouTube-Client-Name`.
  public let clientNameHeader: Int
  public let userAgent: String?
  public let supportsCookies: Bool
  public let supportsHLS: Bool
  /// Profiles whose stream URLs need `base.js` signature/n-param solving. Never used for playback.
  public let requiresJSPlayer: Bool
  public let extraContext: [String: JSONValue]?

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
