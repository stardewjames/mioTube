import Foundation
import Testing
@testable import MioTubeCore

@Suite @MainActor struct SearchHistoryTests {
  @Test func submittedSearchesPersistAndRepeatedQueriesMoveToFront() throws {
    let suite = "miotube-search-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = SearchHistory(defaults: defaults)
    history.record("  Swift tutorials\n")
    history.record("Music")
    history.record("swift TUTORIALS")
    history.record(" \n\t")

    #expect(history.queries == ["swift TUTORIALS", "Music"])
    let reloadedDefaults = try #require(UserDefaults(suiteName: suite))
    #expect(SearchHistory(defaults: reloadedDefaults).queries == ["swift TUTORIALS", "Music"])
  }

  @Test func retainsNewestThirtyWithoutEvictingOnRepeatedSearch() throws {
    let suite = "miotube-search-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = SearchHistory(defaults: defaults)
    for index in 0...30 { history.record("Search \(index)") }
    #expect(history.queries == (1...30).reversed().map { "Search \($0)" })

    history.record("Search 1")
    let expected = ["Search 1"] + (2...30).reversed().map { "Search \($0)" }
    #expect(history.queries == expected)
    #expect(SearchHistory(defaults: defaults).queries == expected)
  }

  @Test func deletionAndClearSurviveReloadWithoutRemovingOtherPreferences() throws {
    let suite = "miotube-search-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("dark", forKey: "appearance")
    let history = SearchHistory(defaults: defaults)
    history.record("Cats")
    history.record("Dogs")
    history.record("Birds")
    history.remove("Dogs")
    #expect(SearchHistory(defaults: defaults).queries == ["Birds", "Cats"])

    history.removeAll()
    #expect(history.queries.isEmpty)
    #expect(SearchHistory(defaults: defaults).queries.isEmpty)
    #expect(defaults.string(forKey: "appearance") == "dark")
  }

  @Test func matchingPreservesRecencyAndDoesNotSaveTypedText() throws {
    let suite = "miotube-search-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = SearchHistory(defaults: defaults)
    history.record("Swift tutorials")
    history.record("Music")
    history.record("Learning Swift")
    let original = history.queries

    #expect(history.matching("  SWIFT\n") == ["Learning Swift", "Swift tutorials"])
    #expect(history.matching(" \n") == original)
    #expect(history.matching("never submitted").isEmpty)
    #expect(history.queries == original)
    #expect(SearchHistory(defaults: defaults).queries == original)
  }
}
