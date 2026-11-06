import Foundation
import Observation

/// Device-local recent searches, shared across accounts and never synced to YouTube.
@MainActor
@Observable
public final class SearchHistory {
  public private(set) var queries: [String]
  @ObservationIgnored private let defaults: UserDefaults
  private static let key = "searchHistory"
  private static let limit = 30

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    queries = Array((defaults.stringArray(forKey: Self.key) ?? []).prefix(Self.limit))
  }

  /// Only submitted searches belong here, not partially typed text or opened YouTube links.
  public func record(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    queries.insert(trimmed, at: 0)
    if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    persist()
  }

  public func matching(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? queries : queries.filter { $0.localizedCaseInsensitiveContains(trimmed) }
  }

  public func remove(_ query: String) {
    queries.removeAll { $0 == query }
    persist()
  }

  public func removeAll() {
    queries.removeAll()
    defaults.removeObject(forKey: Self.key)
  }

  private func persist() {
    defaults.set(queries, forKey: Self.key)
  }
}
