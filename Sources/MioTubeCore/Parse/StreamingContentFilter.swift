import Foundation

/// Recognises paid / streaming-service content (YouTube Movies & TV, Primetime Channels,
/// pay-per-view and service-locked live events) so feeds and search never show it.
public enum StreamingContentFilter {
  /// Renderers that only ever carry storefront or service content; skipped without descending.
  static let renderers: Set<String> = [
    "movieRenderer", "gridMovieRenderer", "compactMovieRenderer", "showRenderer", "gridShowRenderer",
    "universalWatchCardRenderer", "watchCardHeroVideoRenderer", "ticketShelfRenderer",
    "primetimePromoRenderer",
  ]

  /// Keys that only appear on purchasable / subscription-gated items.
  static let purchaseKeys: Set<String> = [
    "ypcGetOfferEndpoint", "ypcGetOffersEndpoint", "unlimitedYpcGetOffersEndpoint", "ypcOfferEndpoint",
    "ypcTrailerRenderer", "offerRenderer", "ypcGetCartEndpoint",
  ]

  /// Owner names of YouTube's storefront / service channels.
  static let ownerNames: Set<String> = [
    "youtube movies & tv", "youtube movies", "youtube primetime channels", "primetime channels", "youtube tv",
    "nfl sunday ticket",
  ]

  /// Badge / metadata phrases (lower-cased) marking service content. Single words must match
  /// exactly; phrases may prefix longer badge text ("Free with ads · PG-13").
  static let exactPhrases: Set<String> = ["rent", "buy", "ppv", "primetime"]
  static let prefixPhrases = [
    "free with ads", "buy or rent", "pay to watch", "included with", "watch with", "try it free", "try now",
    "start free trial", "free trial", "primetime channel", "sunday ticket", "league pass", "pay-per-view",
    "subscribe to watch", "available on youtube tv",
  ]

  /// Shelf titles (lower-cased) whose whole shelf is service content.
  static let shelfPhrases = [
    "primetime", "movies & tv", "movies & shows", "free with ads", "free movies", "sunday ticket", "youtube tv",
  ]

  public static func isServiceShelf(title: String?) -> Bool {
    guard let title = title?.lowercased() else { return false }
    return shelfPhrases.contains { title.contains($0) }
  }

  public static func isServiceText(_ text: String) -> Bool {
    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lower.isEmpty, lower.count <= 48 else { return false }
    return exactPhrases.contains(lower) || prefixPhrases.contains { lower.hasPrefix($0) }
  }

  public static func isServiceOwner(_ name: String) -> Bool {
    ownerNames.contains(name.lowercased().trimmingCharacters(in: .whitespaces))
  }

  /// Inspects an item renderer's badges, offer endpoints and (for lockups) metadata parts.
  /// Titles are never matched, so a video *called* "Buy" is kept.
  public static func isServiceContent(_ renderer: JSONValue) -> Bool {
    if let parts = renderer["metadata", "lockupMetadataViewModel", "metadata", "contentMetadataViewModel", "metadataRows"]?.array {
      for row in parts {
        for part in row["metadataParts"]?.array ?? [] {
          if let text = part["text", "content"]?.string, isServiceText(text) { return true }
        }
      }
    }
    return containsServiceMarker(renderer)
  }

  private static func containsServiceMarker(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let object):
      for (key, child) in object {
        if purchaseKeys.contains(key) { return true }
        switch key {
        case "metadataBadgeRenderer":
          let style = child["style"]?.string
          let label = child["label"]?.string ?? ""
          // "Fundraiser" shares the YPC style but is a nonprofit donation button.
          if style == "BADGE_STYLE_TYPE_YPC", label.lowercased() != "fundraiser" { return true }
          if isServiceText(label) { return true }
        case "thumbnailBadgeViewModel":
          if let text = child["text"]?.string, isServiceText(text) { return true }
        case "badgeViewModel":
          if let text = child["badgeText"]?.string, isServiceText(text) { return true }
        case "title", "headline", "descriptionSnippet", "detailedMetadataSnippets", "menu":
          continue
        default:
          break
        }
        if containsServiceMarker(child) { return true }
      }
      return false
    case .array(let array):
      return array.contains(where: containsServiceMarker)
    default:
      return false
    }
  }
}
