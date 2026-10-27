import Foundation
import Testing
@testable import MioTubeCore

@Suite struct AdFilterTests {
  @Test func removesEveryAdRendererKeyAndCounts() throws {
    var json = try Fixture.json("ads_synthetic.json")
    let count = AdFilter().filter(&json)
    // adSlotRenderer, isPromoted videoRenderer, statementBannerRenderer, promotedVideoRenderer, searchPyvRenderer
    #expect(count == 5)
    let text = String(decoding: try json.encoded(), as: UTF8.self)
    for key in AdFilter.adRenderers { #expect(!text.contains("\"\(key)\"")) }
    #expect(!text.contains("PROMO0000001"))
    #expect(text.contains("REAL00000001") && text.contains("REAL00000002"))
  }

  @Test func leavesCleanResponsesUntouched() throws {
    var json = try Fixture.json("channel_videos.json")
    let original = json
    #expect(AdFilter().filter(&json) == 0)
    #expect(json == original)
  }

  @Test func streamingServiceContentIsRemoved() throws {
    let page = FeedParser.parse(try Fixture.json("streaming_synthetic.json"))
    // Kept: the fundraiser (YPC style but a donation), a video titled "Buy", an ordinary lockup.
    #expect(page.videos.map(\.videoID) == ["FUNDRAISER01", "PLAINVIDEO01", "NORMALLOCK01"])
    // Removed: Free-with-ads badge, storefront owner, Sunday Ticket live event, movie lockup,
    // the "Free with ads movies" shelf, movieRenderer.
    #expect(page.droppedAds == 6)
    #expect(page.sections.allSatisfy { $0.title == nil })
  }

  @Test func streamingFilterLeavesRealFixturesAlone() throws {
    for name in ["channel_videos.json", "browse_shelves.json", "search.json", "playlist.json"] {
      let page = FeedParser.parse(try Fixture.json(name))
      #expect(page.droppedAds == 0, "\(name)")
    }
  }

  @Test func parserReportsDroppedAds() throws {
    let page = FeedParser.parse(try Fixture.json("ads_synthetic.json"))
    #expect(page.droppedAds == 5)
    #expect(page.videos.map(\.videoID) == ["REAL00000001", "REAL00000002"])
    #expect(page.continuation == "NEXT_TOKEN")
    #expect(page.sections.map(\.title) == [nil, "Trending"])
    let first = try #require(page.videos.first)
    #expect(first.durationSeconds == 245)
    #expect(first.channelID == "UCchannel")
    #expect(page.videos[1].durationSeconds == 3723)
  }
}

@Suite struct FeedParserTests {
  @Test func signedOutHomeIsAnEmptyNudge() throws {
    let page = FeedParser.parse(try Fixture.json("home.json"))
    #expect(page.items.isEmpty)
    #expect(page.droppedAds == 0)
    #expect(page.notice == "Try searching to get started")
  }

  @Test func homeShapedShelvesParse() throws {
    let page = FeedParser.parse(try Fixture.json("browse_shelves.json"))
    #expect(page.sections.count >= 3)
    #expect(page.sections.filter { $0.title != nil }.count >= 3)
    for item in page.items {
      #expect(!item.id.isEmpty)
      #expect(!item.title.isEmpty)
      #expect(!item.title.hasPrefix("Ad"))
    }
  }

  @Test func lockupGridParsesVideosWithMetadata() throws {
    let page = FeedParser.parse(try Fixture.json("channel_videos.json"))
    let videos = page.videos
    #expect(videos.count == 30)
    #expect(page.continuation != nil)
    for video in videos {
      #expect(video.videoID.count == 11)
      #expect(!video.title.isEmpty)
      #expect(video.viewCountText?.hasSuffix("views") == true)
      #expect(video.publishedText?.hasSuffix("ago") == true)
    }
    #expect(videos.contains { $0.durationSeconds != nil })
    #expect(page.tabs.contains { $0.title == "Videos" && $0.isSelected })
    #expect(page.header?.title == "Rick Astley")
  }

  @Test func continuationPageParses() throws {
    let first = FeedParser.parse(try Fixture.json("channel_videos.json"))
    let second = FeedParser.parse(try Fixture.json("channel_videos_page2.json"))
    #expect(second.videos.count >= 20)
    #expect(Set(first.videos.map(\.id)).isDisjoint(with: second.videos.map(\.id)))
  }

  @Test func searchParsesVideosChannelsAndChips() throws {
    let page = FeedParser.parse(try Fixture.json("search.json"))
    #expect(page.videos.count >= 10)
    #expect(page.continuation != nil)
    #expect(page.items.contains { if case .channel = $0 { true } else { false } })
    #expect(page.chips.map(\.title).starts(with: ["All", "Shorts", "Unwatched", "Videos"]))
    #expect(page.chips.first?.isSelected == true)
    #expect(page.chips.dropFirst().allSatisfy { $0.token != nil })
  }

  @Test func searchChipReloadParses() throws {
    let page = FeedParser.parse(try Fixture.json("search_chip.json"))
    #expect(page.videos.count >= 10)
  }

  @Test func playlistLockupsAndViewModelContinuation() throws {
    let page = FeedParser.parse(try Fixture.json("playlist.json"))
    #expect(page.videos.count == 3)
    #expect(page.continuation != nil)
    #expect(page.videos.allSatisfy { $0.channelName == "Rick Astley" })
  }

  @Test func classifierIgnoresPartOrder() {
    #expect(ItemParser.classify("1.3 billion views") == .views)
    #expect(ItemParser.classify("No views") == .views)
    #expect(ItemParser.classify("15y ago") == .published)
    #expect(ItemParser.classify("Streamed 2 days ago") == .published)
    #expect(ItemParser.classify("4.55M subscribers") == .subscribers)
    #expect(ItemParser.classify("Rick Astley") == .other)
  }
}

@Suite struct FeedLoaderTests {
  static func channelSpy() -> SpyTransport {
    SpyTransport { request in
      let body = request.jsonBody
      let name = body?["continuation"] != nil ? "channel_videos_page2.json" : "channel_videos.json"
      return HTTPResponse(status: 200, data: try Fixture.data(name))
    }
  }

  @Test func secondLoadIsServedFromCache() async throws {
    let spy = Self.channelSpy()
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    let key = FeedKey.channel("UCuAXFkgsw1L7xaCfnd5JJOw", .videos)
    let first = try await loader.load(key, forceRefresh: false)
    let requestsAfterFirst = spy.requests.count
    let second = try await loader.load(key, forceRefresh: false)
    #expect(spy.requests.count == requestsAfterFirst)
    #expect(first == second)
  }

  @Test func nextPageAppendsDistinctVideosOnSameEndpoint() async throws {
    let spy = Self.channelSpy()
    let cache = FeedCache(directory: nil)
    let loader = FeedLoader(client: try makeClient(spy), cache: cache)
    let key = FeedKey.channel("UCuAXFkgsw1L7xaCfnd5JJOw", .videos)
    let first = try await loader.load(key, forceRefresh: false)
    let next = try #require(try await loader.nextPage(key))
    #expect(Set(first.videos.map(\.id)).isDisjoint(with: next.videos.map(\.id)))
    #expect(spy.requests.last?.url.path == "/youtubei/v1/browse")
    #expect(spy.requests.last?.jsonBody?["continuation"]?.string == first.continuation)
    let merged = try #require(await cache.page(for: key))
    #expect(merged.videos.count == first.videos.count + next.videos.count)
  }

  @Test func cachePersistsAcrossInstances() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miotube-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let page = FeedParser.parse(try Fixture.json("ads_synthetic.json"))
    await FeedCache(directory: dir).store(page, for: .search("swift"), endpoint: "search")
    let reopened = FeedCache(directory: dir)
    #expect(await reopened.page(for: .search("swift")) == page)
    #expect(await reopened.endpoint(for: .search("swift")) == "search")
    #expect(await reopened.page(for: .home) == nil)
  }

  @Test func emptySignedOutHomeFallsBackToDestinations() async throws {
    let spy = SpyTransport { request in
      let id = request.jsonBody?["browseId"]?.string
      return HTTPResponse(status: 200, data: try Fixture.data(id == "FEwhat_to_watch" ? "home.json" : "browse_shelves.json"))
    }
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil), homeFallbackBrowseIDs: ["UCa", "UCb"])
    let page = try await loader.load(.home, forceRefresh: true)
    #expect(spy.requests.count == 3)
    #expect(!page.items.isEmpty)
    #expect(page.notice == "Try searching to get started")
    #expect(page.continuation == nil)
  }

  @Test func chipSearchUsesContinuationBody() async throws {
    let spy = SpyTransport(body: try Fixture.data("search_chip.json"))
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    _ = try await loader.load(.search("swift", .continuation("CHIP")), forceRefresh: true)
    #expect(spy.requests.first?.url.path == "/youtubei/v1/search")
    #expect(spy.requests.first?.jsonBody?["continuation"] == "CHIP")
  }

  @Test func suggestionsParse() throws {
    let json = try JSONValue.decode(Data(#"["swift",["swift","swiftui","swift taylor"]]"#.utf8))
    #expect(SearchSuggestions.parse(json) == ["swift", "swiftui", "swift taylor"])
  }
}
