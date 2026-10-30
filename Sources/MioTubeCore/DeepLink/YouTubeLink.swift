import Foundation

/// A YouTube link parsed from either an `https://` web URL or the `youtube://` URL scheme.
public enum YouTubeLink: Hashable, Sendable {
  /// A watchable video: `watch?v=`, `youtu.be/`, `shorts/`, `live/`, `embed/` or `v/`.
  case video(id: String)
  /// A playlist page: `playlist?list=`.
  case playlist(id: String)
  /// A channel, addressed by a `UC…` browse id or an `@handle`.
  case channel(id: String)

  /// Hosts that serve YouTube web pages.
  private static let webHosts: Set<String> = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
  /// Path segments that address a video directly (`/shorts/<id>`, `/live/<id>`, …).
  private static let videoSegments: Set<String> = ["shorts", "live", "embed", "v"]
  /// Query keys carried by custom-scheme URLs (`youtube://watch?v=…`).
  private static let queryVideoKeys = ["v"]
  private static let queryPlaylistKeys = ["list"]

  /// Matches URLs handed over by iOS for the registered `youtube://` / `vnd.youtube://` schemes.
  public init?(url: URL) {
    guard let scheme = url.scheme?.lowercased() else { return nil }
    switch scheme {
    case "http", "https":
      self.init(webURL: url)
    case "youtube", "vnd.youtube":
      // Custom schemes come in two flavors: the host is a YouTube domain
      // (`youtube://www.youtube.com/watch?v=…`) or a page keyword (`youtube://watch?v=…`).
      if let host = url.host, host.lowercased().contains(".") {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        if let web = components?.url, let link = YouTubeLink(webURL: web) {
          self = link
          return
        }
      }
      self.init(schemeHost: url.host, path: url.path, queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    default:
      return nil
    }
  }

  /// Parses a bare link, tolerating text pasted without a scheme (`youtu.be/…`, `youtube.com/watch?v=…`).
  public init?(string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil, let link = YouTubeLink(url: url) {
      self = link
      return
    }
    if let url = URL(string: "https://\(trimmed)"), let link = YouTubeLink(url: url) {
      self = link
      return
    }
    return nil
  }

  /// Standard web URLs (`https://www.youtube.com/…`, `https://youtu.be/…`).
  private init?(webURL url: URL) {
    guard let host = url.host?.lowercased() else { return nil }
    // Match the full host or a subdomain of it, so `notyoutube.com` never matches `youtube.com`.
    let isYouTubeHost = Self.webHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    guard isYouTubeHost else { return nil }
    let segments = url.pathComponents.filter { $0 != "/" }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    if host == "youtu.be" || host.hasSuffix(".youtu.be") {
      guard let id = segments.first else { return nil }
      self.init(videoID: id)
      return
    }
    switch segments.first {
    case "watch":
      if let id = Self.query(items, keys: Self.queryVideoKeys) { self.init(videoID: id) }
      else if let id = Self.query(items, keys: Self.queryPlaylistKeys) { self.init(playlistID: id) }
      else { return nil }
    case "playlist":
      guard let id = Self.query(items, keys: Self.queryPlaylistKeys) else { return nil }
      self.init(playlistID: id)
    case let segment? where Self.videoSegments.contains(segment):
      guard segments.count > 1 else { return nil }
      self.init(videoID: segments[1])
    case "channel":
      guard segments.count > 1 else { return nil }
      self.init(channelID: segments[1])
    case let segment? where segment.hasPrefix("@"):
      self.init(channelID: segment)
    default:
      return nil
    }
  }

  /// Custom-scheme URLs whose host is a page keyword rather than a domain.
  private init?(schemeHost host: String?, path: String, queryItems: [URLQueryItem]?) {
    let host = host ?? ""
    let items = queryItems ?? []
    if let id = Self.query(items, keys: Self.queryVideoKeys) {
      self.init(videoID: id)
      return
    }
    if let id = Self.query(items, keys: Self.queryPlaylistKeys) {
      self.init(playlistID: id)
      return
    }
    let segments = path.split(separator: "/").map(String.init)
    switch host {
    case let segment where Self.videoSegments.contains(segment):
      guard segments.count > 0 else { return nil }
      self.init(videoID: segments[0])
    case "channel":
      guard segments.count > 0 else { return nil }
      self.init(channelID: segments[0])
    case let segment where segment.hasPrefix("@"):
      self.init(channelID: segment)
    default:
      return nil
    }
  }

  private init?(videoID: String) {
    guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
    self = .video(id: videoID)
  }

  private init?(playlistID: String) {
    guard playlistID.range(of: #"^[A-Za-z0-9_-]{2,64}$"#, options: .regularExpression) != nil else { return nil }
    self = .playlist(id: playlistID)
  }

  private init?(channelID: String) {
    if channelID.hasPrefix("UC"), channelID.range(of: #"^[A-Za-z0-9_-]{3,64}$"#, options: .regularExpression) != nil {
      self = .channel(id: channelID)
    } else if channelID.hasPrefix("@"),
              channelID.range(of: #"^@[A-Za-z0-9._-]{2,64}$"#, options: .regularExpression) != nil {
      self = .channel(id: channelID)
    } else {
      return nil
    }
  }

  /// First non-empty query value whose key matches, ignoring exact casing.
  private static func query(_ items: [URLQueryItem], keys: [String]) -> String? {
    let match = items.first { item in keys.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame } }
    guard let value = match?.value, !value.isEmpty else { return nil }
    return value
  }
}
