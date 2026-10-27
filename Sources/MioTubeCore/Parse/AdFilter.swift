import Foundation

/// Strips every ad/promoted renderer from an InnerTube response before parsing.
/// Applied once per response in the parsers; views never see ads.
public struct AdFilter: Sendable {
  public static let adRenderers: Set<String> = [
    "adSlotRenderer", "displayAdRenderer", "inFeedAdLayoutRenderer", "promotedSparklesWebRenderer",
    "promotedSparklesTextSearchRenderer", "searchPyvRenderer", "statementBannerRenderer",
    "compactPromotedItemRenderer", "promotedVideoRenderer", "brandVideoShelfRenderer",
    "brandVideoSingletonRenderer", "featuredPromotedSparklesTextRenderer", "adSlotAndLayoutMetadata",
  ]

  public init() {}

  /// Recursively deletes object members whose key is an ad renderer, or whose value is an
  /// object flagged `paidPromotion`/`isPromoted`. Array elements left empty by a deletion
  /// (e.g. `{richItemRenderer: {content: {adSlotRenderer}}}` → `{}` wrappers) are dropped too.
  /// Returns the number of deletions.
  @discardableResult
  public func filter(_ root: inout JSONValue) -> Int {
    var count = 0
    root = strip(root, &count)
    return count
  }

  private func strip(_ value: JSONValue, _ count: inout Int) -> JSONValue {
    switch value {
    case .object(let object):
      var result: [String: JSONValue] = [:]
      result.reserveCapacity(object.count)
      for (key, child) in object {
        if Self.adRenderers.contains(key) || Self.isPromoted(child) {
          count += 1
          continue
        }
        result[key] = strip(child, &count)
      }
      return .object(result)
    case .array(let array):
      var result: [JSONValue] = []
      result.reserveCapacity(array.count)
      for element in array {
        let before = count
        let stripped = strip(element, &count)
        if count > before, Self.isHollow(stripped) { continue }
        result.append(stripped)
      }
      return .array(result)
    default:
      return value
    }
  }

  static func isPromoted(_ value: JSONValue) -> Bool {
    guard case .object(let object) = value else { return false }
    return object["paidPromotion"]?.bool == true || object["isPromoted"]?.bool == true
  }

  /// An object that only wraps other emptied objects.
  static func isHollow(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let object): object.values.allSatisfy(isHollow)
    case .array(let array): array.isEmpty
    default: false
    }
  }
}
