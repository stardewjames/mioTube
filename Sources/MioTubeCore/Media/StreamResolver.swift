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
  /// Same-profile source to try if `source` fails in the player (HLS → muxed MP4).
  public let fallbackSource: PlaybackSource?
  public var id: String { profile }

  public init(
    profile: String, playabilityStatus: String?, reason: String?, hlsManifestURL: URL?, muxedItags: [Int],
    hasAdPlacements: Bool, source: PlaybackSource?, fallbackSource: PlaybackSource? = nil
  ) {
    self.profile = profile
    self.playabilityStatus = playabilityStatus
    self.reason = reason
    self.hlsManifestURL = hlsManifestURL
    self.muxedItags = muxedItags
    self.hasAdPlacements = hasAdPlacements
    self.source = source
    self.fallbackSource = fallbackSource
  }
}

public struct Resolution: Sendable {
  public let source: PlaybackSource
  /// Same-profile source to try once if `source` fails before the profile is abandoned.
  public let fallback: PlaybackSource?
  /// The `player` response that produced `source` (captions, duration, live flag).
  public let player: JSONValue?
  public let profileID: String?
  /// Audio rendition to start on; `nil` when the stream has no alternative renditions or none
  /// can be identified.
  public let audioTrack: AudioTrack?
  public let probes: [ProfileProbe]

  public init(
    source: PlaybackSource, fallback: PlaybackSource? = nil, player: JSONValue?, profileID: String?,
    audioTrack: AudioTrack?, probes: [ProfileProbe]
  ) {
    self.source = source
    self.fallback = fallback
    self.player = player
    self.profileID = profileID
    self.audioTrack = audioTrack
    self.probes = probes
  }
}

public actor StreamResolver {
  public static let cacheLifetime: TimeInterval = 30 * 60

  private let client: InnertubeClient
  private let catalog: ProfileCatalog
  private var cache: [String: (resolution: Resolution, expires: Date, session: GoogleSession?)] = [:]

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
    let session = await sessionSnapshot()
    if excluding.isEmpty, let hit = cache[key], hit.expires > Date(), Self.sameSession(hit.session, session) {
      return hit.resolution
    }
    if !excluding.isEmpty { cache[key] = nil }
    let resolution = await run(
      videoID: videoID, maxHeight: maxHeight, stopAtFirstSuccess: true, excluding: excluding, session: session
    )
    guard !Task.isCancelled, Self.sameSession(session, await sessionSnapshot()) else {
      return Resolution(
        source: .unavailable(PlaybackFailure(reasons: [.init(profile: "all", reason: "Playback account changed or resolution was cancelled")])),
        player: nil, profileID: nil, audioTrack: nil, probes: resolution.probes
      )
    }
    if case .unavailable = resolution.source { return resolution }
    let ttl = min(Self.cacheLifetime, (resolution.player?["streamingData", "expiresInSeconds"]?.double ?? .infinity) - 60)
    if ttl > 0 {
      cache[key] = (resolution, Date().addingTimeInterval(ttl), session)
    }
    return resolution
  }

  /// Diagnostics: every profile, no short-circuit, no cache.
  public func probeAll(videoID: String) async -> [ProfileProbe] {
    let session = await sessionSnapshot()
    return await run(videoID: videoID, maxHeight: nil, stopAtFirstSuccess: false, excluding: [], session: session).probes
  }

  public func invalidate(videoID: String) {
    cache = cache.filter { !$0.key.hasPrefix(videoID + "|") }
  }

  /// The player proved the primary source unplayable and switched to the fallback. Cache the
  /// fallback as the primary so a replay inside the TTL starts on the stream that works.
  public func promoteFallback(videoID: String, matching failedSource: PlaybackSource) {
    for key in Array(cache.keys) where key.hasPrefix(videoID + "|") {
      guard let hit = cache[key], hit.resolution.source == failedSource,
            let fallback = hit.resolution.fallback else { continue }
      cache[key] = (
        Resolution(
          source: fallback, fallback: nil, player: hit.resolution.player,
          profileID: hit.resolution.profileID, audioTrack: hit.resolution.audioTrack,
          probes: hit.resolution.probes
        ),
        hit.expires, hit.session
      )
    }
  }

  // MARK: Profile loop

  private func run(
    videoID: String, maxHeight: Int?, stopAtFirstSuccess: Bool, excluding: Set<String>, session: GoogleSession?
  ) async -> Resolution {
    var probes: [ProfileProbe] = []
    var offline = false
    for id in catalog.playbackOrder {
      guard !Task.isCancelled, Self.sameSession(session, await sessionSnapshot()) else {
        probes.append(.skipped(id, "cancelled: playback account changed"))
        break
      }
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
      if offline {
        probes.append(.skipped(id, "skipped: network unavailable"))
        continue
      }
      do {
        let json = try await client.post(
          "player", Self.playerBody(videoID: videoID, profileID: id), profileID: id,
          authenticated: session != nil, expectedSession: profile.supportsCookies ? session : nil
        )
        guard !Task.isCancelled, Self.sameSession(session, await sessionSnapshot()) else {
          probes.append(.skipped(id, "cancelled: playback account changed"))
          break
        }
        let probe = Self.evaluate(json, profile: profile, maxHeight: maxHeight, expectedVideoID: videoID)
        probes.append(probe)
        if let source = probe.source, stopAtFirstSuccess {
          return Resolution(
            source: source, fallback: probe.fallbackSource, player: json, profileID: id,
            audioTrack: AudioTrack.preferred(in: json), probes: probes
          )
        }
      } catch is CancellationError {
        probes.append(.skipped(id, "cancelled: playback account changed"))
        break
      } catch MioTubeError.transport(let message) {
        offline = true
        probes.append(.skipped(id, message))
      } catch {
        probes.append(.skipped(id, String(describing: error)))
      }
    }
    if !stopAtFirstSuccess, let success = probes.first(where: { $0.source != nil }), let source = success.source {
      return Resolution(
        source: source, fallback: success.fallbackSource, player: nil, profileID: success.profile,
        audioTrack: nil, probes: probes
      )
    }
    let reasons = probes.map { PlaybackFailure.Reason(profile: $0.profile, reason: $0.reason ?? "no playable formats") }
    return Resolution(
      source: .unavailable(PlaybackFailure(reasons: reasons)), player: nil, profileID: nil, audioTrack: nil, probes: probes
    )
  }

  private func sessionSnapshot() async -> GoogleSession? {
    guard let session = await client.session.current(), session.hasAuthCookie, session.expiresAt > Date() else { return nil }
    return session
  }

  private static func sameSession(_ lhs: GoogleSession?, _ rhs: GoogleSession?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let lhs?, let rhs?): return lhs.hasSameIdentity(as: rhs)
    default: return false
    }
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
  static func evaluate(
    _ json: JSONValue, profile: ClientProfile, maxHeight: Int?, expectedVideoID: String? = nil
  ) -> ProfileProbe {
    let status = json["playabilityStatus", "status"]?.string
    let hasAds = json["adPlacements"] != nil || json["playerAds"] != nil || json["adSlots"] != nil
    let hls = json["streamingData", "hlsManifestUrl"]?.string.flatMap(playableURL)
    let formats = json["streamingData", "formats"]?.array ?? []
    let itags = formats.compactMap { $0["itag"]?.int }
    func probe(_ reason: String?, _ source: PlaybackSource?, fallback: PlaybackSource? = nil) -> ProfileProbe {
      ProfileProbe(
        profile: profile.id, playabilityStatus: status, reason: reason, hlsManifestURL: hls, muxedItags: itags,
        hasAdPlacements: hasAds, source: source, fallbackSource: fallback
      )
    }
    if let expectedVideoID, let actualVideoID = json["videoDetails", "videoId"]?.string,
       actualVideoID != expectedVideoID {
      return probe("player returned a different video", nil)
    }
    guard status == "OK" else {
      let reason = json["playabilityStatus", "reason"]?.string
        ?? json["playabilityStatus", "errorScreen"]?.first(key: "reason")?.text
        ?? (status.map { "status \($0)" } ?? "no playabilityStatus")
      return probe(reason, nil)
    }
    let progressive = bestProgressive(formats, maxHeight: maxHeight ?? 1080)
    if let hls, profile.supportsHLS, !needsJSTransform(hls) {
      // Keep the muxed rendition: if the manifest is rejected by AVPlayer, the same profile
      // can still play instead of being abandoned for the next one.
      return probe(nil, .hls(hls), fallback: progressive.map { .progressive($0) })
    }
    if let progressive {
      return probe(nil, .progressive(progressive))
    }
    return probe("no playable formats", nil)
  }

  /// Muxed H.264/AAC MP4 with a plain URL, not a cipher, DRM, or JS challenge.
  static func bestProgressive(_ formats: [JSONValue], maxHeight: Int) -> URL? {
    let candidates: [(itag: Int, height: Int, url: URL)] = formats.compactMap { format in
      guard let mime = format["mimeType"]?.string, mime.hasPrefix("video/mp4"),
            mime.contains("avc1"), mime.contains("mp4a"),
            format["drmFamilies"]?.array?.isEmpty ?? true,
            format["type"]?.string != "FORMAT_STREAM_TYPE_OTF",
            let raw = format["url"]?.string, let url = playableURL(raw), !needsJSTransform(url),
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

  /// Both direct URLs and manifest paths can carry a JS `n` challenge.
  static func needsJSTransform(_ url: URL) -> Bool {
    let queryChallenge = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
      $0.name == "n"
    } ?? false
    return queryChallenge || url.pathComponents.contains("n")
  }

  private static func playableURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
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
