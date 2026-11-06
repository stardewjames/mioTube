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
    #expect(info.description.hasPrefix("The official video"))
    #expect(info.commentsContinuation != nil)
    #expect(info.durationSeconds == 213)
    #expect(!info.isLive)
    #expect(info.related.count >= 10)
    #expect(!info.related.contains { $0.videoID == "dQw4w9WgXcQ" })
    #expect(info.captionTracks.contains { $0.languageCode == "en" && $0.name == "English" })
  }

  @Test func explicitLiveFlagsOverrideFiniteDuration() {
    let players: [JSONValue] = [
      ["videoDetails": ["isLive": true, "lengthSeconds": "3600"]],
      [
        "videoDetails": ["lengthSeconds": "3600"],
        "microformat": ["playerMicroformatRenderer": ["liveBroadcastDetails": ["isLiveNow": true]]],
      ],
    ]
    for player in players {
      let info = WatchParser.parse(next: .null, player: player, adFilter: .init())
      #expect(info.isLive)
      #expect(info.durationSeconds == 3600)
    }
  }

  @Test func explicitFinishedFlagsPreserveArchives() {
    let next = Self.livePrimary
    let players: [JSONValue] = [
      ["videoDetails": ["isLive": false, "isLiveContent": true, "lengthSeconds": "3600"]],
      [
        "videoDetails": ["isLiveContent": true, "lengthSeconds": "3600"],
        "microformat": ["playerMicroformatRenderer": ["liveBroadcastDetails": ["isLiveNow": false]]],
      ],
      [
        "videoDetails": ["isLive": false, "isLiveContent": true],
        "microformat": ["playerMicroformatRenderer": ["liveBroadcastDetails": ["isLiveNow": true]]],
      ],
    ]
    for player in players {
      #expect(!WatchParser.parse(next: next, player: player, adFilter: .init()).isLive)
    }
  }

  @Test func primaryLiveFlagSurvivesMissingAuthoritativePlayerFlag() {
    let players: [JSONValue] = [
      .null,
      ["videoDetails": ["lengthSeconds": "3600"]],
      ["videoDetails": ["isLiveContent": true, "lengthSeconds": "3600"]],
    ]
    for player in players {
      #expect(WatchParser.parse(next: Self.livePrimary, player: player, adFilter: .init()).isLive)
    }
  }

  @Test func liveContentAloneDoesNotTurnFiniteArchivesIntoLiveStreams() {
    let archive: JSONValue = ["videoDetails": ["isLiveContent": true, "lengthSeconds": "3600"]]
    #expect(!WatchParser.parse(next: .null, player: archive, adFilter: .init()).isLive)
    let active: JSONValue = ["videoDetails": ["isLiveContent": true, "lengthSeconds": "0"]]
    #expect(WatchParser.parse(next: .null, player: active, adFilter: .init()).isLive)
  }

  @Test func activeStreamsSuppressChaptersButArchivesKeepThem() throws {
    let next = try Fixture.json("watch_chapters.json")
    let live: JSONValue = ["videoDetails": ["isLive": true, "lengthSeconds": "3600"]]
    #expect(WatchParser.parse(next: next, player: live, adFilter: .init()).chapters.isEmpty)
    let archive: JSONValue = ["videoDetails": ["isLive": false, "isLiveContent": true, "lengthSeconds": "3600"]]
    #expect(!WatchParser.parse(next: next, player: archive, adFilter: .init()).chapters.isEmpty)
  }

  private static var livePrimary: JSONValue {
    ["contents": ["twoColumnWatchNextResults": ["results": ["results": ["contents": [
      ["videoPrimaryInfoRenderer": ["viewCount": ["videoViewCountRenderer": ["isLive": true]]]]
    ]]]]]]
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

  /// Verbatim shape of YouTube's auto-generated VTT (2026): rolling cues + 10 ms fillers.
  @Test func autoGeneratedRollingCuesShowEachLineOnce() throws {
    let vtt = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:12.719 --> 00:00:14.829 align:start position:0%
     
    welcome<00:00:13.000><c> to</c><00:00:13.120><c> Swift</c><00:00:13.400><c> UI</c>

    00:00:14.829 --> 00:00:14.839 align:start position:0%
    welcome to Swift UI
     

    00:00:14.839 --> 00:00:16.349 align:start position:0%
    welcome to Swift UI
    video<00:00:15.120><c> I'm</c><00:00:15.200><c> going</c>

    00:00:16.349 --> 00:00:16.359 align:start position:0%
    video I'm going
     

    00:00:16.359 --> 00:00:17.870 align:start position:0%
    video I'm going
    what<00:00:16.480><c> we're</c><00:00:16.640><c> learning</c>
    """
    let captions = CaptionsParser.parse(vtt)
    #expect(captions.cues.map(\.text) == ["welcome to Swift UI", "video I'm going", "what we're learning"])
    #expect(try #require(captions.cue(at: 13)).text == "welcome to Swift UI")
    #expect(try #require(captions.cue(at: 15.5)).text == "video I'm going")
  }

  @Test func forbiddenTrackReportsFailure() async {
    let spy = SpyTransport(status: 403, body: Data())
    let track = CaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=x&fmt=srv3")!, languageCode: "en", name: "English", isAutomatic: false)
    await #expect(throws: MioTubeError.self) { try await CaptionsParser.fetch(track, transport: spy) }
    #expect(spy.requests.count == 1)
  }

  @Test func signedCaptionQuerySurvivesFormatConversionByteForByte() throws {
    let base = URL(string: "https://www.youtube.com/api/timedtext?v=x&signature=a%2Bb%2Fc%3D&fmt=srv3&xosf=1&lang=en")!
    let converted = try CaptionsParser.webVTTURL(base)
    #expect(converted.absoluteString == "https://www.youtube.com/api/timedtext?v=x&signature=a%2Bb%2Fc%3D&lang=en&fmt=vtt")
  }

  @Test func emptyAndNonCaptionResponsesAreNotSuccessfulTranscripts() async {
    let track = CaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=x")!, languageCode: "en", name: "English", isAutomatic: false)
    for body in ["", "<html>consent required</html>", "00:00:01.000 --> 00:00:02.000\nnot WebVTT"] {
      let spy = SpyTransport(body: Data(body.utf8))
      await #expect(throws: MioTubeError.self) { try await CaptionsParser.fetch(track, transport: spy) }
    }
  }

  @Test func validVTTResponseReachesCaptionConsumer() async throws {
    let track = CaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=x")!, languageCode: "en", name: "English", isAutomatic: false)
    let spy = SpyTransport(body: Data(Self.vtt.utf8))
    let captions = try await CaptionsParser.fetch(track, transport: spy)
    #expect(captions.cue(at: 1.5)?.text == "Hello & welcome")
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
    #expect(failure.reasons.last?.reason == "no playable formats")
    #expect(spy.requests.count == catalog.playbackOrder.count)
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
    #expect(await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ").profileID == "visionos")
    let fallback = await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ", excluding: ["visionos"])
    #expect(fallback.profileID == "web_safari")
    #expect(fallback.probes.first?.reason == "skipped: stream failed in player")
    // The fallback replaced the cached bad resolution.
    #expect(await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ").profileID == "web_safari")
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

  /// Multi-audio videos list dubs next to the original; only the original carries
  /// `audioIsDefault`. Picking anything else plays the wrong language.
  @Test func prefersTheDefaultAudioTrackOverDubs() {
    let json: JSONValue = [
      "streamingData": [
        "adaptiveFormats": [
          ["audioTrack": ["displayName": "Español", "id": "es.3", "audioIsDefault": false]],
          ["audioTrack": ["displayName": "English (US) original", "id": "en-US.4", "audioIsDefault": true]],
          ["audioTrack": ["displayName": "Español", "id": "es.3", "audioIsDefault": false]],
        ]
      ]
    ]
    #expect(AudioTrack.preferred(in: json) == AudioTrack(id: "en-US.4", languageTag: "en-US"))
  }

  /// Without the flag, the stream URL's `xtags` still marks which rendition is the original.
  @Test func fallsBackToOriginalMarkerInStreamURL() {
    let json: JSONValue = [
      "streamingData": [
        "adaptiveFormats": [
          ["audioTrack": ["id": "es.3"], "url": "https://v/a?xtags=acont%3Ddubbed%3Alang%3Des"],
          ["audioTrack": ["id": "en-US.4"], "url": "https://v/a?xtags=acont%3Doriginal%3Alang%3Den-US"],
        ]
      ]
    ]
    #expect(AudioTrack.preferred(in: json) == AudioTrack(id: "en-US.4", languageTag: "en-US"))
  }

  /// Several unmarked renditions: guessing is what produced the wrong language, so choose none.
  @Test func unmarkedAlternativesYieldNoChoice() {
    let ambiguous: JSONValue = [
      "streamingData": [
        "adaptiveFormats": [
          ["audioTrack": ["id": "es.3"]],
          ["audioTrack": ["id": "en-US.4"]],
        ]
      ]
    ]
    #expect(AudioTrack.preferred(in: ambiguous) == nil)
    let single: JSONValue = ["streamingData": ["adaptiveFormats": [["audioTrack": ["id": "en-US.4"]]]]]
    #expect(AudioTrack.preferred(in: single) == AudioTrack(id: "en-US.4", languageTag: "en-US"))
    #expect(AudioTrack.preferred(in: ["playabilityStatus": ["status": "OK"]]) == nil)
  }

  @Test func trackIDLanguageTagDropsTheCounter() {
    #expect(AudioTrack.languageTag(fromTrackID: "en-US.4") == "en-US")
    #expect(AudioTrack.languageTag(fromTrackID: "es-419.4") == "es-419")
    #expect(AudioTrack.languageTag(fromTrackID: "en-US") == "en-US")
    #expect(AudioTrack.languageTag(fromTrackID: ".4") == nil)
  }

  /// HLS `LANGUAGE` and the track id need not be identical (`en-US` vs `en`); match exact first.
  @Test func renditionMatchingPrefersExactTagThenLanguage() {
    let track = AudioTrack(id: "en-US.4", languageTag: "en-US")
    #expect(track.preferredRenditionIndex(in: [nil, "ar", "en-US", "en"]) == 2)
    #expect(track.preferredRenditionIndex(in: ["es-419", "en"]) == 1)
    #expect(AudioTrack(id: "en_US.4", languageTag: "en_US").preferredRenditionIndex(in: [nil, "en-us"]) == 1)
    #expect(track.preferredRenditionIndex(in: [nil, "de"]) == nil)
  }

  @Test func hlsResolutionCarriesMuxedFallback() async throws {
    let json: JSONValue = [
      "playabilityStatus": ["status": "OK"],
      "streamingData": [
        "hlsManifestUrl": "https://manifest.googlevideo.com/variant",
        "formats": [
          [
            "itag": 22, "height": 720,
            "mimeType": "video/mp4; codecs=\"avc1.64001F, mp4a.40.2\"", "url": "https://v/22",
          ],
          [
            "itag": 18, "height": 360,
            "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "url": "https://v/18",
          ],
        ],
      ],
    ]
    let spy = SpyTransport(body: try json.encoded())
    let resolution = await StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
      .resolveDetailed(videoID: "v")
    guard case .hls = resolution.source else {
      Issue.record("expected hls, got \(resolution.source)")
      return
    }
    guard case .progressive(let fallback)? = resolution.fallback else {
      Issue.record("expected a progressive fallback")
      return
    }
    #expect(fallback.absoluteString == "https://v/22")
    #expect(resolution.probes.last?.fallbackSource == resolution.fallback)
  }

  @Test func promotedFallbackReplacesCachedPrimary() async throws {
    let json: JSONValue = [
      "playabilityStatus": ["status": "OK"],
      "streamingData": [
        "hlsManifestUrl": "https://manifest.googlevideo.com/variant",
        "formats": [[
          "itag": 18, "height": 360,
          "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "url": "https://v/18",
        ]],
      ],
    ]
    let spy = SpyTransport(body: try json.encoded())
    let resolver = StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
    _ = await resolver.resolveDetailed(videoID: "v")
    await resolver.promoteFallback(
      videoID: "v", matching: .hls(URL(string: "https://manifest.googlevideo.com/variant")!)
    )
    let promoted = await resolver.resolveDetailed(videoID: "v")
    guard case .progressive(let url) = promoted.source else {
      Issue.record("expected promoted progressive source, got \(promoted.source)")
      return
    }
    #expect(url.absoluteString == "https://v/18")
    #expect(promoted.fallback == nil)
    #expect(spy.requests.count == 1)
  }

  @Test func progressiveResolutionHasNoFallback() async throws {
    let json: JSONValue = [
      "playabilityStatus": ["status": "OK"],
      "streamingData": [
        "formats": [[
          "itag": 18, "height": 360,
          "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "url": "https://v/18",
        ]]
      ],
    ]
    let spy = SpyTransport(body: try json.encoded())
    let resolution = await StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
      .resolveDetailed(videoID: "v")
    guard case .progressive = resolution.source else {
      Issue.record("expected progressive, got \(resolution.source)")
      return
    }
    #expect(resolution.fallback == nil)
  }

  @Test func resolutionCarriesTheOriginalAudioTrack() async throws {
    let json: JSONValue = [
      "playabilityStatus": ["status": "OK"],
      "streamingData": [
        "hlsManifestUrl": "https://manifest.googlevideo.com/variant",
        "adaptiveFormats": [
          ["audioTrack": ["id": "es.3", "audioIsDefault": false]],
          ["audioTrack": ["id": "en-US.4", "audioIsDefault": true]],
        ],
      ],
    ]
    let spy = SpyTransport(body: try json.encoded())
    let resolution = await StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
      .resolveDetailed(videoID: "v")
    #expect(resolution.audioTrack == AudioTrack(id: "en-US.4", languageTag: "en-US"))
  }

  @Test func invalidOrChallengedManifestsDoNotReachTheNativePlayer() throws {
    let profile = try #require(testCatalog().profile("visionos"))
    for url in ["relative.m3u8", "file:///video.m3u8", "http://manifest.googlevideo.com/x", "https://manifest.googlevideo.com/api/n/challenge/playlist/index.m3u8"] {
      let json: JSONValue = [
        "playabilityStatus": ["status": "OK"],
        "streamingData": ["hlsManifestUrl": .string(url)],
      ]
      #expect(StreamResolver.evaluate(json, profile: profile, maxHeight: nil).source == nil)
    }
  }

  @Test func protectedOrUnmuxedProgressiveFormatsAreNotNativeSources() {
    let formats: [JSONValue] = [
      ["itag": 18, "mimeType": "video/mp4; codecs=\"avc1, mp4a\"", "url": "https://v/drm", "drmFamilies": ["WIDEVINE"]],
      ["itag": 22, "mimeType": "video/mp4; codecs=\"avc1\"", "url": "https://v/no-audio"],
      ["itag": 18, "mimeType": "video/mp4; codecs=\"avc1, mp4a\"", "url": "https://v/otf", "type": "FORMAT_STREAM_TYPE_OTF"],
    ]
    #expect(StreamResolver.bestProgressive(formats, maxHeight: 1080) == nil)
  }

  @Test func mismatchedVideoDoesNotReachTheNativePlayer() throws {
    let profile = try #require(testCatalog().profile("visionos"))
    let player: JSONValue = [
      "playabilityStatus": ["status": "OK"], "videoDetails": ["videoId": "other"],
      "streamingData": ["hlsManifestUrl": "https://manifest.googlevideo.com/video.m3u8"],
    ]
    #expect(StreamResolver.evaluate(player, profile: profile, maxHeight: nil, expectedVideoID: "wanted").source == nil)
  }

  @Test func switchingAccountsDoesNotReuseThePreviousAccountsResolution() async throws {
    let store = InMemorySessionStore(testSession)
    let spy = SpyTransport(body: try Fixture.data("player_visionos.json"))
    let catalog = try testCatalog()
    let client = InnertubeClient(transport: spy, catalog: catalog, session: store, locale: .enUS)
    let resolver = StreamResolver(client: client, catalog: catalog)
    _ = await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ")
    await store.save(nil)
    _ = await resolver.resolveDetailed(videoID: "dQw4w9WgXcQ")
    #expect(spy.requests.count == 2)
  }

  @Test func nearExpiredServerURLsAreNotCachedPastTheirLifetime() async throws {
    let player: JSONValue = [
      "playabilityStatus": ["status": "OK"],
      "streamingData": ["hlsManifestUrl": "https://manifest.googlevideo.com/video.m3u8", "expiresInSeconds": "1"],
    ]
    let spy = SpyTransport(body: try player.encoded())
    let resolver = StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
    _ = await resolver.resolveDetailed(videoID: "video")
    _ = await resolver.resolveDetailed(videoID: "video")
    #expect(spy.requests.count == 2)
  }

  @Test func explicitOriginalAudioWinsOverTheClientsDefaultDub() {
    let player: JSONValue = ["streamingData": ["adaptiveFormats": [
      ["audioTrack": ["id": "es.3", "audioIsDefault": true], "url": "https://v/dub?xtags=acont%3Ddubbed%3Alang%3Des"],
      ["audioTrack": ["id": "en-US.4", "audioIsDefault": false], "url": "https://v/original?xtags=acont%3Doriginal%3Alang%3Den-US"],
    ]]]
    #expect(AudioTrack.preferred(in: player) == AudioTrack(id: "en-US.4", languageTag: "en-US"))
  }

  @Test func anonymousTVFallbackCanUseClearFormatsRatherThanAssumingAllTVResponsesAreDRM() async throws {
    let spy = SpyTransport { request in
      if request.jsonBody?["context", "client", "clientName"]?.string == "TVHTML5" {
        return HTTPResponse(status: 200, data: Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"formats":[{"itag":18,"mimeType":"video/mp4; codecs=\"avc1, mp4a\"","url":"https://v/clear"}]}}"#.utf8))
      }
      return HTTPResponse(status: 200, data: Data(#"{"playabilityStatus":{"status":"UNPLAYABLE"}}"#.utf8))
    }
    let resolver = StreamResolver(client: try makeClient(spy), catalog: try testCatalog())
    let resolution = await resolver.resolveDetailed(videoID: "video")
    #expect(resolution.profileID == "tv")
    #expect(resolution.source == .progressive(URL(string: "https://v/clear")!))
    #expect(spy.requests.last?.headers["Cookie"] == nil)
  }
}

extension StreamResolverTests {
  @Test func accountChangeDuringResolutionCannotReturnOrContinueTheOldOperation() async throws {
    let store = InMemorySessionStore(testSession)
    let transport = AccountChangingPlayerTransport(store: store, player: try Fixture.data("player_visionos.json"))
    let catalog = try testCatalog()
    let client = InnertubeClient(transport: transport, catalog: catalog, session: store, locale: .enUS)
    let result = await StreamResolver(client: client, catalog: catalog).resolveDetailed(videoID: "dQw4w9WgXcQ")
    #expect(result.source.url == nil)
    #expect(await transport.calls == 1)
  }
}

private actor AccountChangingPlayerTransport: HTTPTransport {
  let store: InMemorySessionStore
  let player: Data
  private(set) var calls = 0

  init(store: InMemorySessionStore, player: Data) {
    self.store = store
    self.player = player
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    calls += 1
    await store.save(GoogleSession(cookies: ["SAPISID": "replacement-account"], expiresAt: .distantFuture))
    return HTTPResponse(status: 200, data: player)
  }
}
