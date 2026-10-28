import Foundation

public struct PlaybackFailure: Sendable, Equatable, Error {
  public struct Reason: Sendable, Equatable, Hashable {
    public let profile: String
    public let reason: String

    public init(profile: String, reason: String) {
      self.profile = profile
      self.reason = reason
    }
  }

  public let reasons: [Reason]

  public init(reasons: [Reason]) {
    self.reasons = reasons
  }
}

/// The seam between metadata and the player. A DASH-repackaging source can be added as a new
/// case without touching UI.
public enum PlaybackSource: Sendable, Equatable {
  case hls(URL)
  case progressive(URL)
  case unavailable(PlaybackFailure)

  public var url: URL? {
    switch self {
    case .hls(let url), .progressive(let url): url
    case .unavailable: nil
    }
  }
}

/// One profile's answer, kept for Diagnostics.
public struct ProfileProbe: Sendable, Identifiable, Equatable {
  public let profile: String
  public let playabilityStatus: String?
  public let reason: String?
  public let hlsManifestURL: URL?
  public let muxedItags: [Int]
  public let hasAdPlacements: Bool
  public let source: PlaybackSource?
  public var id: String { profile }

  public init(
    profile: String, playabilityStatus: String?, reason: String?, hlsManifestURL: URL?, muxedItags: [Int],
    hasAdPlacements: Bool, source: PlaybackSource?
  ) {
    self.profile = profile
    self.playabilityStatus = playabilityStatus
    self.reason = reason
    self.hlsManifestURL = hlsManifestURL
    self.muxedItags = muxedItags
    self.hasAdPlacements = hasAdPlacements
    self.source = source
  }
}

public struct Resolution: Sendable {
  public let source: PlaybackSource
  /// The `player` response that produced `source` (captions, duration, live flag).
  public let player: JSONValue?
  public let profileID: String?
  /// Audio rendition to start on; `nil` when the stream has no alternative renditions or none
  /// can be identified.
  public let audioTrack: AudioTrack?
  public let probes: [ProfileProbe]
}

public actor StreamResolver {
  public static let cacheLifetime: TimeInterval = 30 * 60

  private let client: InnertubeClient
  private let catalog: ProfileCatalog
  private var cache: [String: (resolution: Resolution, expires: Date)] = [:]

  public init(client: InnertubeClient, catalog: ProfileCatalog) {
    self.client = client
    self.catalog = catalog
  }

  /// Never throws; failures come back as `.unavailable` with one reason per profile in
  /// `playbackOrder`.
  public func resolve(videoID: String, maxHeight: Int? = nil) async -> PlaybackSource {
    await resolveDetailed(videoID: videoID, maxHeight: maxHeight).source
  }

  /// `excluding` skips profiles whose stream already failed in the player; such calls bypass
  /// the cache and replace the cached (bad) resolution.
  public func resolveDetailed(videoID: String, maxHeight: Int? = nil, excluding: Set<String> = []) async -> Resolution {
    let key = "\(videoID)|\(maxHeight ?? 1080)"
    if excluding.isEmpty, let hit = cache[key], hit.expires > Date() { return hit.resolution }
    if !excluding.isEmpty { cache[key] = nil }
    let resolution = await run(videoID: videoID, maxHeight: maxHeight, stopAtFirstSuccess: true, excluding: excluding)
    if case .unavailable = resolution.source { return resolution }
    let ttl = min(Self.cacheLifetime, (resolution.player?["streamingData", "expiresInSeconds"]?.double ?? .infinity) - 60)
    cache[key] = (resolution, Date().addingTimeInterval(max(ttl, 60)))
    return resolution
  }

  /// Diagnostics: every profile, no short-circuit, no cache.
  public func probeAll(videoID: String) async -> [ProfileProbe] {
    await run(videoID: videoID, maxHeight: nil, stopAtFirstSuccess: false, excluding: []).probes
  }

  public func invalidate(videoID: String) {
    cache = cache.filter { !$0.key.hasPrefix(videoID + "|") }
  }

  // MARK: Profile loop

  private func run(videoID: String, maxHeight: Int?, stopAtFirstSuccess: Bool, excluding: Set<String>) async -> Resolution {
    let hasSession = await client.hasSession()
    var probes: [ProfileProbe] = []
    var offline = false
    for id in catalog.playbackOrder {
      guard let profile = catalog.profile(id) else {
        probes.append(.skipped(id, "unknown profile"))
        continue
      }
      if excluding.contains(id) {
        probes.append(.skipped(id, "skipped: stream failed in player"))
        continue
      }
      if profile.requiresJSPlayer {
        probes.append(.skipped(id, "skipped: requires JS player"))
        continue
      }
      // TV without cookies only returns DRM formats.
      if id == "tv" && !hasSession {
        probes.append(.skipped(id, "skipped: requires sign-in"))
        continue
      }
      if offline {
        probes.append(.skipped(id, "skipped: network unavailable"))
        continue
      }
      do {
        let json = try await client.post("player", Self.playerBody(videoID: videoID, profileID: id), profileID: id)
        let probe = Self.evaluate(json, profile: profile, maxHeight: maxHeight)
        probes.append(probe)
        if let source = probe.source, stopAtFirstSuccess {
          return Resolution(
            source: source, player: json, profileID: id, audioTrack: AudioTrack.preferred(in: json), probes: probes
          )
        }
      } catch MioTubeError.transport(let message) {
        offline = true
        probes.append(.skipped(id, message))
      } catch {
        probes.append(.skipped(id, String(describing: error)))
      }
    }
    if !stopAtFirstSuccess, let success = probes.first(where: { $0.source != nil }), let source = success.source {
      return Resolution(source: source, player: nil, profileID: success.profile, audioTrack: nil, probes: probes)
    }
    let reasons = probes.map { PlaybackFailure.Reason(profile: $0.profile, reason: $0.reason ?? "no playable formats") }
    return Resolution(
      source: .unavailable(PlaybackFailure(reasons: reasons)), player: nil, profileID: nil, audioTrack: nil, probes: probes
    )
  }

  /// No ad context of any kind is sent: no `adPlaybackContext`, `playerAdParams`, or
  /// `SUPPORTS_AD_PLAYBACK_CONTEXT`.
  static func playerBody(videoID: String, profileID: String) -> JSONValue {
    var body: [String: JSONValue] = [
      "videoId": .string(videoID),
      "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
      "contentCheckOk": true,
      "racyCheckOk": true,
    ]
    if profileID == "web_embedded" {
      body["context"] = ["thirdParty": ["embedUrl": "https://www.youtube.com/"]]
    }
    return .object(body)
  }

  /// Pure decision for one `player` response. `adPlacements`/`playerAds`/`adSlots` are only
  /// recorded, never acted on.
  static func evaluate(_ json: JSONValue, profile: ClientProfile, maxHeight: Int?) -> ProfileProbe {
    let status = json["playabilityStatus", "status"]?.string
    let hasAds = json["adPlacements"] != nil || json["playerAds"] != nil || json["adSlots"] != nil
    let hls = json["streamingData", "hlsManifestUrl"]?.string.flatMap(URL.init(string:))
    let formats = json["streamingData", "formats"]?.array ?? []
    let itags = formats.compactMap { $0["itag"]?.int }
    func probe(_ reason: String?, _ source: PlaybackSource?) -> ProfileProbe {
      ProfileProbe(
        profile: profile.id, playabilityStatus: status, reason: reason, hlsManifestURL: hls, muxedItags: itags,
        hasAdPlacements: hasAds, source: source
      )
    }
    guard status == "OK" else {
      let reason = json["playabilityStatus", "reason"]?.string
        ?? json["playabilityStatus", "errorScreen"]?.first(key: "reason")?.text
        ?? (status.map { "status \($0)" } ?? "no playabilityStatus")
      return probe(reason, nil)
    }
    if let hls, profile.supportsHLS {
      return probe(nil, .hls(hls))
    }
    if let url = bestProgressive(formats, maxHeight: maxHeight ?? 1080) {
      return probe(nil, .progressive(url))
    }
    return probe("no playable formats", nil)
  }

  /// Muxed H.264 with a plain `url`. Cipher-protected entries and URLs carrying the `n`
  /// throttling parameter both need the `base.js` transform, so they are skipped (an
  /// untransformed `n` URL answers 403).
  static func bestProgressive(_ formats: [JSONValue], maxHeight: Int) -> URL? {
    let candidates: [(itag: Int, height: Int, url: URL)] = formats.compactMap { format in
      guard let mime = format["mimeType"]?.string, mime.contains("avc1"),
            let raw = format["url"]?.string, let url = URL(string: raw), !needsJSTransform(url),
            let itag = format["itag"]?.int else { return nil }
      let height = format["height"]?.int ?? (itag == 22 ? 720 : itag == 18 ? 360 : 0)
      guard height <= maxHeight else { return nil }
      return (itag, height, url)
    }
    if let preferred = candidates.first(where: { $0.itag == 22 }) ?? candidates.first(where: { $0.itag == 18 }) {
      return preferred.url
    }
    return candidates.max { $0.height < $1.height }?.url
  }

  /// Web-family stream URLs carry an `n` query parameter that must be rewritten by the
  /// player JS; the Apple clients' URLs do not.
  static func needsJSTransform(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "n" } ?? false
  }
}

extension ProfileProbe {
  static func skipped(_ profile: String, _ reason: String) -> ProfileProbe {
    ProfileProbe(
      profile: profile, playabilityStatus: nil, reason: reason, hlsManifestURL: nil, muxedItags: [],
      hasAdPlacements: false, source: nil
    )
  }
}
