import Foundation

public enum SponsorCategory: String, Codable, CaseIterable, Sendable, Hashable {
  case sponsor
  case selfpromo
  case exclusiveAccess = "exclusive_access"
  case interaction
  case poiHighlight = "poi_highlight"
  case intro
  case outro
  case preview
  case hook
  case filler
  case chapter
  case musicOfftopic = "music_offtopic"

  public var displayName: String {
    switch self {
    case .sponsor: "Sponsor"
    case .selfpromo: "Self-promotion"
    case .exclusiveAccess: "Exclusive access"
    case .interaction: "Interaction reminder"
    case .poiHighlight: "Highlight"
    case .intro: "Intro"
    case .outro: "Endcards/credits"
    case .preview: "Preview/recap"
    case .hook: "Hook/greetings"
    case .filler: "Filler tangent"
    case .chapter: "Chapter"
    case .musicOfftopic: "Non-music section"
    }
  }
}

public enum SponsorAction: String, Codable, Sendable, Hashable, CaseIterable {
  case skip, mute, full, poi, chapter
}

public struct SponsorSegment: Sendable, Hashable, Codable {
  public let uuid: String
  public let start: Double
  public let end: Double
  public let category: SponsorCategory
  public let action: SponsorAction
  public let votes: Int

  public init(uuid: String, start: Double, end: Double, category: SponsorCategory, action: SponsorAction, votes: Int) {
    self.uuid = uuid
    self.start = start
    self.end = end
    self.category = category
    self.action = action
    self.votes = votes
  }
}

/// In-memory, per-video, 6 h.
public actor SponsorBlockCache {
  public static let lifetime: TimeInterval = 6 * 3600
  private var entries: [String: (segments: [SponsorSegment], stored: Date)] = [:]

  public init() {}

  public func segments(for key: String) -> [SponsorSegment]? {
    guard let entry = entries[key], Date().timeIntervalSince(entry.stored) < Self.lifetime else { return nil }
    return entry.segments
  }

  public func store(_ segments: [SponsorSegment], for key: String) {
    entries[key] = (segments, Date())
  }
}

public actor SponsorBlockClient {
  public static let defaultServer = URL(string: "https://sponsor.ajay.app")!

  private let transport: any HTTPTransport
  private let cache: SponsorBlockCache

  public init(transport: any HTTPTransport, cache: SponsorBlockCache) {
    self.transport = transport
    self.cache = cache
  }

  public func segments(
    videoID: String, categories: [SponsorCategory], server: URL, privacyMode: Bool
  ) async throws -> [SponsorSegment] {
    let cacheKey = "\(server.absoluteString)|\(videoID)|\(categories.map(\.rawValue).sorted().joined(separator: ","))"
    if let cached = await cache.segments(for: cacheKey) { return cached }
    let request = Self.request(videoID: videoID, categories: categories, server: server, privacyMode: privacyMode)
    let data: Data
    do {
      data = try await transport.send(request).data
    } catch MioTubeError.http(let status, _) where status == 404 || status == 204 {
      await cache.store([], for: cacheKey)
      return []
    }
    let segments = try Self.decode(data, videoID: videoID, hashed: privacyMode)
    await cache.store(segments, for: cacheKey)
    return segments
  }

  static func request(videoID: String, categories: [SponsorCategory], server: URL, privacyMode: Bool) -> HTTPRequest {
    let path = privacyMode ? "api/skipSegments/\(sha256Hex(videoID).prefix(4))" : "api/skipSegments"
    var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    var items: [URLQueryItem] = []
    if !privacyMode { items.append(URLQueryItem(name: "videoID", value: videoID)) }
    items.append(URLQueryItem(name: "categories", value: jsonArray(categories.map(\.rawValue))))
    items.append(URLQueryItem(name: "actionTypes", value: jsonArray(SponsorAction.allCases.map(\.rawValue))))
    components.queryItems = items
    // URLComponents leaves `[`, `]` and `"` alone in some Foundations; encode them explicitly.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
      .replacingOccurrences(of: "\"", with: "%22")
    return HTTPRequest(url: components.url!, headers: ["Accept": "application/json"], timeout: 10)
  }

  static func jsonArray(_ values: [String]) -> String {
    "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
  }

  static func decode(_ data: Data, videoID: String, hashed: Bool) throws -> [SponsorSegment] {
    let json = try JSONValue.decode(data)
    let raw: [JSONValue]
    if hashed {
      raw = (json.array ?? []).filter { $0["videoID"]?.string == videoID }.flatMap { $0["segments"]?.array ?? [] }
    } else {
      raw = json.array ?? []
    }
    return raw.compactMap { item in
      guard let pair = item["segment"]?.array, pair.count == 2,
            let start = pair[0].double, let end = pair[1].double,
            let uuid = item["UUID"]?.string,
            let category = item["category"]?.string.flatMap(SponsorCategory.init(rawValue:))
      else { return nil }
      let action = item["actionType"]?.string.flatMap(SponsorAction.init(rawValue:)) ?? .skip
      return SponsorSegment(uuid: uuid, start: start, end: end, category: category, action: action, votes: item["votes"]?.int ?? 0)
    }
    .sorted { $0.start < $1.start }
  }
}
