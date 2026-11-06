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
  /// Thread-safe call counter for request handlers.
  final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
      lock.withLock {
        value += 1
        return value
      }
    }
  }

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

  @Test func forcedReloadReplacesTheCachedPage() async throws {
    let first = try Fixture.data("channel_videos.json")
    let second = try Fixture.data("channel_videos_page2.json")
    let counter = LockedCounter()
    let spy = SpyTransport { _ in HTTPResponse(status: 200, data: counter.next() == 1 ? first : second) }
    let cache = FeedCache(directory: nil)
    let loader = FeedLoader(client: try makeClient(spy), cache: cache)
    let key = FeedKey.channel("UCuAXFkgsw1L7xaCfnd5JJOw", .home)

    let firstPage = try await loader.load(key, forceRefresh: true)
    let reloaded = try await loader.load(key, forceRefresh: true)

    #expect(spy.requests.count == 2)
    #expect(!reloaded.videos.isEmpty)
    #expect(reloaded.videos.first?.videoID != firstPage.videos.first?.videoID)
    #expect(await cache.page(for: key) == reloaded)
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

  @Test func signedOutHomeShowsOnlyTheNudge() async throws {
    let spy = SpyTransport(body: try Fixture.data("home.json"))
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    let page = try await loader.load(.home, forceRefresh: true)
    // No destination-channel requests: their sections are special sections, not Home content.
    #expect(spy.requests.count == 1)
    #expect(page.items.isEmpty)
    #expect(page.sections.isEmpty)
    #expect(page.notice == "Try searching to get started")
    #expect(page.continuation == nil)
  }

  @Test func homeDropsSpecialSectionsButKeepsRecommendations() async throws {
    let spy = SpyTransport(body: try Fixture.data("ads_synthetic.json"))
    let cache = FeedCache(directory: nil)
    let loader = FeedLoader(client: try makeClient(spy), cache: cache)
    let page = try await loader.load(.home, forceRefresh: true)
    #expect(page.sections.count == 1 && page.sections[0].title == nil)
    #expect(page.videos.map(\.videoID) == ["REAL00000001"])
    #expect(page.continuation == "NEXT_TOKEN")

    // A Home snapshot cached before the filter must render clean on first paint too.
    await cache.store(FeedParser.parse(try Fixture.json("ads_synthetic.json")), for: .home, endpoint: "browse")
    let cachedPage = await loader.cached(.home)
    let cached = try #require(cachedPage)
    #expect(cached.sections.count == 1 && cached.sections[0].title == nil)
  }

  @Test func homeContinuationAlsoDropsSpecialSections() async throws {
    let spy = SpyTransport(body: try Fixture.data("ads_synthetic.json"))
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    _ = try await loader.load(.home, forceRefresh: true)
    let continuationPage = try await loader.nextPage(.home)
    let next = try #require(continuationPage)
    #expect(!next.sections.isEmpty && next.sections.allSatisfy { $0.title == nil })
  }

  @Test func otherFeedsKeepTheirShelves() async throws {
    let spy = SpyTransport(body: try Fixture.data("browse_shelves.json"))
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    let page = try await loader.load(.channel("UCx", .home), forceRefresh: true)
    #expect(page.sections.contains { $0.title != nil })
  }

  @Test func chipSearchUsesContinuationBody() async throws {
    let spy = SpyTransport(body: try Fixture.data("search_chip.json"))
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    _ = try await loader.load(.search("swift", .continuation("CHIP")), forceRefresh: true)
    #expect(spy.requests.first?.url.path == "/youtubei/v1/search")
    #expect(spy.requests.first?.jsonBody?["continuation"] == "CHIP")
  }

  @Test func suggestionsDecodeOnlyFixedJSONPAndReadNestedRows() throws {
    let data = Data(#"window.google.ac.h(["swift",[["swift",0,[512]],["swiftui",0,[512]]],{}]);"#.utf8)
    let json = try #require(SearchSuggestions.decode(data))
    #expect(SearchSuggestions.parse(json) == ["swift", "swiftui"])
    #expect(SearchSuggestions.decode(Data(#"evil(["swift",[]])"#.utf8)) == nil)
  }

  @Test func suggestionsUseWebQueryFamilyAndRejectHTTPFailure() async throws {
    let spy = SpyTransport(body: Data(#"window.google.ac.h(["swift",[["swiftui",0,[512]]]])"#.utf8))
    #expect(await SearchSuggestions(transport: spy, hl: "fr", gl: "CA").suggestions(for: " swift ") == ["swiftui"])
    let request = try #require(spy.requests.first)
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(request.url.host == "www.youtube.com" && request.url.path == "/complete/search")
    #expect(query.contains(URLQueryItem(name: "client", value: "youtube")))
    #expect(query.contains(URLQueryItem(name: "gl", value: "CA")))
    #expect(query.contains(URLQueryItem(name: "q", value: "swift")))
    let failed = SpyTransport { _ in HTTPResponse(status: 503, data: Data(#"window.google.ac.h(["swift",[["wrong"]]])"#.utf8)) }
    #expect(await SearchSuggestions(transport: failed, hl: "en").suggestions(for: "swift").isEmpty)
  }

  @Test func localizedChannelTabUsesNavigationURLAndOpaqueParams() async throws {
    let landing: JSONValue = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
      ["tabRenderer": ["title": "Accueil", "selected": true, "content": ["sectionListRenderer": ["contents": []]]]],
      ["tabRenderer": ["title": "En direct", "endpoint": [
        "commandMetadata": ["webCommandMetadata": ["url": "/@channel/streams"]],
        "browseEndpoint": ["browseId": "UC1", "params": "opaque%3D%3D"],
      ]]],
    ]]]]
    let spy = SpyTransport { request in
      HTTPResponse(status: 200, data: try (request.jsonBody?["params"] == nil ? landing : ["contents": [:]]).encoded())
    }
    let loader = FeedLoader(client: try makeClient(spy), cache: FeedCache(directory: nil))
    _ = try await loader.load(.channel("UC1", .live), forceRefresh: true)
    #expect(spy.requests.count == 2)
    #expect(spy.requests.last?.jsonBody?["params"] == "opaque%3D%3D")
  }

  @Test func errorAlertIsNotAnEmptyPlaylistAndIsNotCached() async throws {
    let spy = SpyTransport(body: Data(#"{"alerts":[{"alertRenderer":{"type":"ERROR","text":{"simpleText":"The playlist does not exist."}}}]}"#.utf8))
    let cache = FeedCache(directory: nil)
    let loader = FeedLoader(client: try makeClient(spy), cache: cache)
    await #expect(throws: MioTubeError.self) { try await loader.load(.playlist("missing"), forceRefresh: true) }
    #expect(await cache.page(for: .playlist("missing")) == nil)
  }
}

extension FeedParserTests {
  @Test func commentRepliesAcceptNestedViewModelsAndPreserveSortTokens() {
    let page = CommentsParser.parse([
      "frameworkUpdates": ["entityBatchUpdate": ["mutations": [[
        "entityKey": "entity", "payload": ["commentEntityPayload": [
          "properties": ["commentId": "reply", "content": ["content": "A real reply"], "publishedTime": "1 day ago"],
          "author": ["displayName": "@author"], "toolbar": ["replyCount": "2", "likeCountNotliked": "4"],
        ]],
      ]]]],
      "onResponseReceivedEndpoints": [["appendContinuationItemsAction": ["continuationItems": [
        ["commentsHeaderRenderer": ["sortMenu": ["sortFilterSubMenuRenderer": ["subMenuItems": [
          ["title": "Newest", "selected": true, "serviceEndpoint": ["continuationCommand": ["token": "sort%3D"]]],
        ]]]]],
        ["commentViewModel": ["commentViewModel": ["commentKey": "entity"]]],
        ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "next%3D"]]]],
      ]]]],
    ])
    #expect(page.comments.first?.id == "reply")
    #expect(page.comments.first?.text == "A real reply")
    #expect(page.comments.first?.replyCount == 2)
    #expect(page.continuation == "next%3D")
    #expect(page.sortOptions.first?.token == "sort%3D" && page.sortOptions.first?.isSelected == true)
  }
}
