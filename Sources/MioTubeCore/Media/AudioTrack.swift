import Foundation

/// The audio rendition that is the video's own audio. YouTube lists auto-dubs and creator-track
/// dubs as siblings of it, and on those videos its HLS manifest marks every rendition
/// `DEFAULT=NO`, so leaving the choice to AVFoundation plays a dub whose position in the
/// manifest depends on the video.
public struct AudioTrack: Sendable, Hashable {
  /// `player`'s identity for the track, e.g. `"en-US.4"`.
  public let id: String
  /// BCP-47 tag parsed from `id` (`"en-US.4"` → `"en-US"`), matched against HLS `LANGUAGE`.
  public let languageTag: String

  public init(id: String, languageTag: String) {
    self.id = id
    self.languageTag = languageTag
  }

  /// Index into the audible renditions to select: exact tag match first, then primary language
  /// (`en-US` fits a `LANGUAGE="en"` rendition). `nil` when nothing matches, in which case the
  /// player leaves AVFoundation's own choice alone.
  public func preferredRenditionIndex(in tags: [String?]) -> Int? {
    let wanted = Self.normalized(languageTag)
    if let exact = tags.firstIndex(where: { $0.map(Self.normalized) == wanted }) { return exact }
    let wantedLanguage = wanted.split(separator: "-").first.map(String.init) ?? wanted
    return tags.firstIndex { tag in
      guard let normalized = tag.map(Self.normalized), !normalized.isEmpty else { return false }
      return normalized.split(separator: "-").first.map(String.init) == wantedLanguage
    }
  }

  static func normalized(_ tag: String) -> String {
    tag.replacingOccurrences(of: "_", with: "-").lowercased()
  }

  /// Picks the track to start on from a `player` response: the one flagged `audioIsDefault`
  /// (the video's original audio), else the one marked `acont=original` in the stream URL, else
  /// the sole track. `nil` when several tracks exist and none is marked — guessing there is how
  /// the wrong language gets played.
  static func preferred(in player: JSONValue?) -> AudioTrack? {
    guard let streaming = player?["streamingData"] else { return nil }
    let formats = (streaming["adaptiveFormats"]?.array ?? []) + (streaming["formats"]?.array ?? [])
    var tracks: [AudioTrack] = []
    var seen = Set<String>()
    var defaultID: String?
    var originalIDs = Set<String>()
    for format in formats {
      guard let raw = format["audioTrack"], let id = raw["id"]?.string,
            seen.insert(id).inserted, let tag = languageTag(fromTrackID: id) else { continue }
      tracks.append(AudioTrack(id: id, languageTag: tag))
      if raw["audioIsDefault"]?.bool == true { defaultID = defaultID ?? id }
      if xtags(in: format["url"]?.string)?.contains("acont=original") == true { originalIDs.insert(id) }
    }
    if let defaultID, let track = tracks.first(where: { $0.id == defaultID }) { return track }
    if let original = tracks.first(where: { originalIDs.contains($0.id) }) { return original }
    return tracks.count == 1 ? tracks.first : nil
  }

  /// `"es-419.4"` → `"es-419"`; a trailing all-digit component is YouTube's track counter.
  static func languageTag(fromTrackID id: String) -> String? {
    var parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count > 1, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
      parts.removeLast()
    }
    let tag = parts.joined(separator: ".")
    return tag.isEmpty ? nil : tag
  }

  static func xtags(in url: String?) -> String? {
    guard let url, let items = URLComponents(string: url)?.queryItems else { return nil }
    return items.first { $0.name == "xtags" }?.value
  }
}
