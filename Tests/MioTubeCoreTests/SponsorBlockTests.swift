import Foundation
import Testing
@testable import MioTubeCore

private func segment(
  _ start: Double, _ end: Double, _ category: SponsorCategory = .sponsor, _ action: SponsorAction = .skip, id: String? = nil
) -> SponsorSegment {
  SponsorSegment(uuid: id ?? "\(category.rawValue)-\(start)", start: start, end: end, category: category, action: action, votes: 1)
}

@Suite struct SkipEngineTests {
  let all = Set(SponsorCategory.allCases)

  @Test func boundaryExactlyAtStartSkips() {
    var engine = SkipEngine(segments: [segment(10, 20)], enabled: all)
    #expect(engine.evaluate(position: 10, muted: false) == .skip(to: 20, segment: segment(10, 20)))
  }

  @Test func insideTiltWindowSkipsButJustOutsideDoesNot() {
    var engine = SkipEngine(segments: [segment(10, 20)], enabled: all)
    #expect(engine.evaluate(position: 9.94, muted: false) == .none)
    #expect(engine.evaluate(position: 9.96, muted: false) == .skip(to: 20, segment: segment(10, 20)))
  }

  @Test func exitingMuteSegmentRestoresVolume() {
    let mute = segment(10, 20, .musicOfftopic, .mute)
    var engine = SkipEngine(segments: [mute], enabled: all)
    #expect(engine.evaluate(position: 9, muted: false) == .none)
    #expect(engine.evaluate(position: 12, muted: false) == .mute(true, segment: mute))
    #expect(engine.evaluate(position: 13, muted: true) == .none)
    #expect(engine.evaluate(position: 21, muted: true) == .mute(false, segment: nil))
    #expect(engine.evaluate(position: 22, muted: false) == .none)
  }

  @Test func userMuteOverrideHoldsUntilSegmentChanges() {
    let first = segment(10, 20, .musicOfftopic, .mute)
    let second = segment(30, 40, .musicOfftopic, .mute)
    var engine = SkipEngine(segments: [first, second], enabled: all)
    #expect(engine.evaluate(position: 11, muted: false) == .mute(true, segment: first))
    engine.userToggledMute()
    #expect(engine.evaluate(position: 12, muted: false) == .none)
    #expect(engine.evaluate(position: 21, muted: false) == .none) // user owns volume now
    #expect(engine.evaluate(position: 31, muted: false) == .mute(true, segment: second))
  }

  @Test func disabledCategoryIsIgnored() {
    var engine = SkipEngine(segments: [segment(10, 20, .intro)], enabled: [.sponsor])
    #expect(engine.evaluate(position: 10, muted: false) == .none)
    #expect(engine.segments.isEmpty)
  }

  @Test func adjacentSegmentsSkipToSecondEnd() {
    let a = segment(10, 20)
    let b = segment(20, 30, .selfpromo)
    var engine = SkipEngine(segments: [b, a], enabled: all)
    #expect(engine.evaluate(position: 10, muted: false) == .skip(to: 30, segment: a))
  }

  @Test func fullVideoLabelNeverSkips() {
    var engine = SkipEngine(segments: [segment(0, 0, .exclusiveAccess, .full), segment(0, 300, .sponsor, .full)], enabled: all)
    #expect(engine.fullVideoSponsored)
    #expect(engine.evaluate(position: 0, muted: false) == .none)
    #expect(engine.evaluate(position: 100, muted: false) == .none)
  }

  @Test func poiAndChapterAreNeverDecisions() {
    var engine = SkipEngine(segments: [segment(5, 5.1, .poiHighlight, .poi), segment(0, 50, .chapter, .chapter)], enabled: all)
    #expect(engine.evaluate(position: 5, muted: false) == .none)
  }

  @Test func categoryOverrideTurnsSkipIntoMute() {
    let s = segment(10, 20)
    var engine = SkipEngine(segments: [s], enabled: all, categoryOverrides: [.sponsor: .mute])
    #expect(engine.evaluate(position: 10, muted: false) == .mute(true, segment: s))
  }

  @Test func suppressedSegmentIsNotSkippedAgain() {
    let s = segment(10, 20)
    var engine = SkipEngine(segments: [s], enabled: all)
    engine.suppress(s)
    #expect(engine.evaluate(position: 10, muted: false) == .none)
  }

  @Test func upcomingSkipChainsAndIgnoresMuteAndSuppressed() {
    let mute = segment(20, 30, .musicOfftopic, .mute)
    let a = segment(40, 60)
    let b = segment(60, 90, .selfpromo)
    let later = segment(200, 230, id: "later")
    var engine = SkipEngine(segments: [later, b, mute, a], enabled: all)
    let next = engine.upcomingSkip(after: 10)
    #expect(next?.segment == a)
    #expect(next?.target == 90)
    // Once inside/after a, the lookahead moves on; b is part of a's chain but still a segment.
    #expect(engine.upcomingSkip(after: 100)?.segment == later)
    engine.suppress(later)
    #expect(engine.upcomingSkip(after: 100) == nil)
  }

  @Test func longEarlierSegmentStillFoundBehindShortOnes() {
    let long = segment(0, 100, id: "long")
    let short = segment(5, 6, .selfpromo, id: "short")
    var engine = SkipEngine(segments: [long, short], enabled: all)
    #expect(engine.evaluate(position: 50, muted: false) == .skip(to: 100, segment: long))
  }
}

@Suite struct SponsorBlockClientTests {
  static let body = Data(#"""
  [{"segment":[12.5,30],"UUID":"u1","category":"sponsor","actionType":"skip","votes":3},
   {"segment":[1,2],"UUID":"u2","category":"unknown_future","actionType":"skip","votes":0},
   {"segment":[40,50],"UUID":"u3","category":"music_offtopic","actionType":"mute","votes":1}]
  """#.utf8)

  @Test func requestEncodesJSONArrays() async throws {
    let spy = SpyTransport(body: Self.body)
    let client = SponsorBlockClient(transport: spy, cache: SponsorBlockCache())
    let segments = try await client.segments(
      videoID: "abc", categories: [.sponsor, .musicOfftopic], server: SponsorBlockClient.defaultServer, privacyMode: false
    )
    #expect(segments.map(\.uuid) == ["u1", "u3"])
    #expect(segments[1].action == .mute)
    let url = try #require(spy.requests.first?.url.absoluteString)
    #expect(url.hasPrefix("https://sponsor.ajay.app/api/skipSegments?videoID=abc&categories=%5B%22sponsor%22,%22music_offtopic%22%5D"))
    #expect(url.contains("actionTypes=%5B%22skip%22,%22mute%22,%22full%22,%22poi%22,%22chapter%22%5D"))
    _ = try await client.segments(videoID: "abc", categories: [.musicOfftopic, .sponsor], server: SponsorBlockClient.defaultServer, privacyMode: false)
    #expect(spy.requests.count == 1)
  }

  @Test func privacyModeUsesHashPrefixAndFilters() async throws {
    #expect(sha256Hex("AbCdEf123456").prefix(4) == "94eb")
    let hashed = Data(#"[{"videoID":"AbCdEf123456","segments":[{"segment":[1,5],"UUID":"mine","category":"sponsor","actionType":"skip"}]},{"videoID":"Other","segments":[{"segment":[1,5],"UUID":"theirs","category":"sponsor","actionType":"skip"}]}]"#.utf8)
    let spy = SpyTransport(body: hashed)
    let client = SponsorBlockClient(transport: spy, cache: SponsorBlockCache())
    let segments = try await client.segments(videoID: "AbCdEf123456", categories: [.sponsor], server: SponsorBlockClient.defaultServer, privacyMode: true)
    #expect(segments.map(\.uuid) == ["mine"])
    let url = try #require(spy.requests.first?.url)
    #expect(url.path == "/api/skipSegments/94eb")
    #expect(!(url.query ?? "").contains("AbCdEf123456"))
  }

  @Test func notFoundMeansNoSegments() async throws {
    let spy = SpyTransport(status: 404, body: Data("Not Found".utf8))
    let client = SponsorBlockClient(transport: spy, cache: SponsorBlockCache())
    let segments = try await client.segments(videoID: "x", categories: [.sponsor], server: SponsorBlockClient.defaultServer, privacyMode: false)
    #expect(segments.isEmpty)
  }
}

@Suite struct StoreTests {
  @Test func resumeRulesAndRetention() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = WatchProgressStore(fileURL: file)
    await store.record(videoID: "mid", position: 120, duration: 600)
    await store.record(videoID: "start", position: 10, duration: 600)
    await store.record(videoID: "end", position: 590, duration: 600)
    await store.record(videoID: "old", position: 120, duration: 600, at: Date().addingTimeInterval(-91 * 86_400))
    await store.flush()
    let reopened = WatchProgressStore(fileURL: file)
    #expect(await reopened.resumePosition(for: "mid") == 120)
    #expect(await reopened.resumePosition(for: "start") == 0)
    #expect(await reopened.resumePosition(for: "end") == 0)
    #expect(await reopened.progress(for: "old") == nil)
  }

  @MainActor
  @Test func settingsPersistThroughUserDefaults() throws {
    let suite = "miotube-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = Settings(defaults: defaults)
    #expect(settings.enabledSponsorCategories == Settings.defaultEnabledCategories)
    #expect(settings.sponsorServerURL == SponsorBlockClient.defaultServer)
    settings.enabledSponsorCategories = [.intro]
    settings.sponsorCategoryActions = [.sponsor: .mute]
    settings.defaultQuality = .p720
    settings.sponsorBlockEnabled = false
    let reloaded = Settings(defaults: defaults)
    #expect(reloaded.enabledSponsorCategories == [.intro])
    #expect(reloaded.sponsorCategoryActions == [.sponsor: .mute])
    #expect(reloaded.defaultQuality == .p720)
    #expect(reloaded.activeSponsorCategories.isEmpty)
    #expect(defaults.stringArray(forKey: "enabledSponsorCategories") == ["intro"])
  }
}
