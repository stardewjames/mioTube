import Foundation
import Testing
@testable import MioTubeCore

@Suite struct WatchParserTests {
  @Test func parsesRickrollWatchPage() throws {
    let info = WatchParser.parse(
      next: try Fixture.json("watch_next.json"), player: try Fixture.json("player_visionos.json"), adFilter: .init()
    )
    #expect(info.videoID == "dQw4w9WgXcQ")
    #expect(info.title.contains("Never Gonna Give You Up"))
    #expect(info.viewCountText?.hasSuffix("views") == true)
    #expect(info.likeCountText == "19M")
    #expect(info.likeStatus == .none)
    #expect(info.channel?.channelID == "UCuAXFkgsw1L7xaCfnd5JJOw")
    #expect(info.channel?.title == "Rick Astley")
    #expect(info.channel?.subscriberText == "4.55M subscribers")
    #expect(info.subscribe == SubscribeState(channelID: "UCuAXFkgsw1L7xaCfnd5JJOw", params: "EgIIAxgAIgtkUXc0dzlXZ1hjUQ%3D%3D", isSubscribed: false))
    #expect(info.description.hasPrefix("The official video"))
    #expect(info.commentsContinuation != nil)
    #expect(info.durationSeconds == 213)
    #expect(!info.isLive)
    #expect(info.related.count >= 10)
    #expect(!info.related.contains { $0.videoID == "dQw4w9WgXcQ" })
    #expect(info.captionTracks.contains { $0.languageCode == "en" && $0.name == "English" })
  }

  @Test func chaptersAscendFromPlayerBar() throws {
    let next = try Fixture.json("watch_chapters.json")
    let info = WatchParser.parse(next: next, player: .null, adFilter: .init())
    #expect(info.chapters.count >= 2)
    #expect(info.chapters.first?.startSeconds == 0)
    #expect(info.chapters.first?.title == "What you will learn & updates")
    #expect(zip(info.chapters, info.chapters.dropFirst()).allSatisfy { $0.startSeconds < $1.startSeconds })
    #expect(!info.related.contains { $0.videoID == info.videoID })
  }

  @Test func descriptionTimestampsOnlyForSameVideo() {
    let content = "0:00 Intro\n1:05 Main part\nOther video 0:00"
    let next: JSONValue = [
      "currentVideoEndpoint": ["watchEndpoint": ["videoId": "SELF"]],
      "x": ["attributedDescription": [
        "content": .string(content),
        "commandRuns": [
          ["startIndex": 0, "length": 4, "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": "SELF", "startTimeSeconds": 0]]]],
          ["startIndex": 11, "length": 4, "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": "SELF", "startTimeSeconds": 65]]]],
          ["startIndex": 39, "length": 4, "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": "OTHER", "startTimeSeconds": 0]]]],
        ],
      ]],
    ]
    let chapters = WatchParser.chapters(next, videoID: "SELF")
    #expect(chapters == [Chapter(title: "Intro", startSeconds: 0), Chapter(title: "Main part", startSeconds: 65)])
  }

  @Test func commentsViewModelsResolveEntities() throws {
    let page = CommentsParser.parse(try Fixture.json("comments.json"))
    #expect(page.comments.count == 20)
    let first = try #require(page.comments.first)
    #expect(first.author == "@grustache4569")
    #expect(first.text.hasPrefix("I Rick rolled my entire French class"))
    #expect(first.likeCountText == "106K")
    #expect(first.replyCount == 645)
    #expect(first.repliesContinuation != nil)
    #expect(page.continuation != nil)
    #expect(page.sortOptions.map(\.title) == ["Top", "Newest"])
    #expect(page.sortOptions.first?.isSelected == true)
  }
}

@Suite struct CaptionsTests {
  static let vtt = """
  WEBVTT
  Kind: captions
  Language: en

  1
  00:00:01.000 --> 00:00:02.500 align:start position:0%
  <c>Hello</c> &amp; welcome

  2
  00:00:03.000 --> 00:00:06.000
  It&#39;s a
  two-line cue
  """

  @Test func parsesCuesAndFindsByTime() throws {
    let captions = CaptionsParser.parse(Self.vtt)
    #expect(captions.cues.count == 2)
    #expect(captions.cues[0].text == "Hello & welcome")
    let cue = try #require(captions.cue(at: 3.5))
    #expect(cue.start == 3 && cue.end == 6)
    #expect(cue.text == "It's a\ntwo-line cue")
    #expect(captions.cue(at: 2.7) == nil)
    #expect(captions.cue(at: 0.5) == nil)
    #expect(captions.cue(at: 7) == nil)
  }

  @Test func forbiddenTrackIsUnavailable() async {
    let spy = SpyTransport(status: 403, body: Data())
    let track = CaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=x&fmt=srv3")!, languageCode: "en", name: "English", isAutomatic: false)
    #expect(await CaptionsParser.fetch(track, transport: spy) == nil)
    #expect(spy.requests.count == 1)
    let query = spy.requests.first?.url.query ?? ""
    #expect(query.contains("fmt=vtt") && !query.contains("fmt=srv3"))
  }
}

@Suite struct StreamResolverTests {
  @Test func noStreamingDataListsEveryProfileInOrder() async throws {
    let spy = SpyTransport(body: Data(#"{"playabilityStatus":{"status":"OK"}}"#.utf8))
    let client = try makeClient(spy)
    let catalog = try testCatalog()
    let source = await StreamResolver(client: client, catalog: catalog).resolve(videoID: "abc")
    guard case .unavailable(let failure) = source else {
      Issue.record("expected unavailable, got \(source)")
      return
    }
    #expect(failure.reasons.map(\.profile) == catalog.playbackOrder)
    #expect(failure.reasons.first?.reason == "no playable formats")
    #expect(failure.reasons.last?.reason == "skipped: requires sign-in")
    // tv is skipped without a session, so one fewer request than profiles.
    #expect(spy.requests.count == catalog.playbackOrder.count - 1)
  }

  @Test func fallsThroughToNextHLSProfile() async throws {
    let unplayable = try Fixture.data("player.json")
    let playable = try Fixture.data("player_visionos.json")
    let spy = SpyTransport { request in
      let name = request.jsonBody?["context", "client", "clientName"]?.string
      return HTTPResponse(status: 200, data: name == "WEB_EMBEDDED_PLAYER" ? playable : unplayable)
    }
    let resolver = StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
    let resolution = await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ")
    guard case .hls(let url) = resolution.source else {
      Issue.record("expected hls, got \(resolution.source)")
      return
    }
    #expect(url.host == "manifest.googlevideo.com")
    #expect(resolution.profileID == "web_embedded")
    #expect(resolution.probes.map(\.profile) == ["visionos", "web_safari", "mweb", "web_embedded"])
    #expect(resolution.probes[0].reason == "Video unavailable")
    let requests = spy.requests.count
    _ = await resolver.resolve(videoID: "dQw4w9WgXcQ")
    #expect(spy.requests.count == requests) // cached
    // No ad context is ever requested.
    for request in spy.requests {
      let body = String(decoding: request.body ?? Data(), as: UTF8.self)
      #expect(!body.contains("adPlaybackContext") && !body.contains("playerAdParams"))
    }
    #expect(spy.requests.last?.jsonBody?["context", "thirdParty", "embedUrl"] != nil)
  }

  /// Regression: signed in, the cookie-carrying web clients answer OK with streams AVPlayer
  /// cannot play; the cookie-less client must still be the one chosen.
  @Test func signedInStillResolvesThroughCookielessClient() async throws {
    let playable = try Fixture.data("player_visionos.json")
    let spy = SpyTransport { _ in HTTPResponse(status: 200, data: playable) }
    let resolver = StreamResolver(client: try makeClient(spy, session: testSession), catalog: try testCatalog())
    let resolution = await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ")
    #expect(resolution.profileID == "visionos")
    #expect(spy.requests.count == 1)
    #expect(spy.requests.first?.headers["Cookie"] == nil)
    #expect(spy.requests.first?.headers["Authorization"] == nil)
  }

  @Test func excludingAFailedProfileBypassesCacheAndFallsThrough() async throws {
    let playable = try Fixture.data("player_visionos.json")
    let spy = SpyTransport { _ in HTTPResponse(status: 200, data: playable) }
    let resolver = StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
    #expect(await resolver.resolveDetailed(videoID: "v").profileID == "visionos")
    let fallback = await resolver.resolveDetailed(videoID: "v", excluding: ["visionos"])
    #expect(fallback.profileID == "web_safari")
    #expect(fallback.probes.first?.reason == "skipped: stream failed in player")
    // The fallback replaced the cached bad resolution.
    #expect(await resolver.resolveDetailed(videoID: "v").profileID == "web_safari")
  }

  @Test func offlineFailsFastWithReasons() async throws {
    let spy = SpyTransport { _ in throw MioTubeError.transport("The Internet connection appears to be offline.") }
    let source = await StreamResolver(client: try makeClient(spy), catalog: try testCatalog()).resolve(videoID: "x")
    guard case .unavailable(let failure) = source else {
      Issue.record("expected unavailable")
      return
    }
    #expect(spy.requests.count == 1)
    #expect(failure.reasons.count == 5)
    #expect(failure.reasons[1].reason == "skipped: network unavailable")
  }

  @Test func progressivePrefersItag22ThenRespectsCap() {
    let formats: [JSONValue] = [
      ["itag": 18, "height": 360, "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "url": "https://v/18"],
      ["itag": 22, "height": 720, "mimeType": "video/mp4; codecs=\"avc1.64001F, mp4a.40.2\"", "url": "https://v/22"],
      ["itag": 43, "height": 360, "mimeType": "video/webm; codecs=\"vp8\"", "url": "https://v/43"],
      ["itag": 37, "height": 1080, "mimeType": "video/mp4; codecs=\"avc1\"", "signatureCipher": "s=x"],
    ]
    #expect(StreamResolver.bestProgressive(formats, maxHeight: 1080)?.absoluteString == "https://v/22")
    #expect(StreamResolver.bestProgressive(formats, maxHeight: 480)?.absoluteString == "https://v/18")
    #expect(StreamResolver.bestProgressive(formats, maxHeight: 240) == nil)
  }

  /// Web-client URLs carry `n=`, which 403s without the base.js transform.
  @Test func progressiveSkipsURLsNeedingNTransform() {
    let formats: [JSONValue] = [
      ["itag": 18, "height": 360, "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "url": "https://v/videoplayback?itag=18&n=AbCdEf&sig=x"],
    ]
    #expect(StreamResolver.bestProgressive(formats, maxHeight: 1080) == nil)
  }
}
