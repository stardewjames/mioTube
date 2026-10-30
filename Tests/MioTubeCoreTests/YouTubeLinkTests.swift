import Testing
@testable import MioTubeCore

@Suite struct YouTubeLinkTests {
  // MARK: Web URLs

  @Test func watchURL() {
    #expect(YouTubeLink(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func watchURLWithPlaylistPrefersVideo() {
    let link = YouTubeLink(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLtest123")
    #expect(link == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func shortURLWithExtras() {
    #expect(YouTubeLink(string: "https://youtu.be/dQw4w9WgXcQ?si=abc&t=42") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func mobileAndMusicHosts() {
    #expect(YouTubeLink(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func shortsLiveEmbedAndPaths() {
    #expect(YouTubeLink(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "https://www.youtube.com/live/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "https://www.youtube.com/v/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func playlistURL() {
    #expect(YouTubeLink(string: "https://www.youtube.com/playlist?list=PLabcdef123456") == .playlist(id: "PLabcdef123456"))
    #expect(YouTubeLink(string: "https://music.youtube.com/playlist?list=PLabcdef123456") == .playlist(id: "PLabcdef123456"))
  }

  @Test func watchURLWithOnlyPlaylist() {
    #expect(YouTubeLink(string: "https://www.youtube.com/watch?list=PLabcdef123456") == .playlist(id: "PLabcdef123456"))
  }

  @Test func channelURLs() {
    #expect(YouTubeLink(string: "https://www.youtube.com/channel/UC1234567890abcdefghij") == .channel(id: "UC1234567890abcdefghij"))
    #expect(YouTubeLink(string: "https://www.youtube.com/@some.handle/videos") == .channel(id: "@some.handle"))
    #expect(YouTubeLink(string: "https://m.youtube.com/@some.handle") == .channel(id: "@some.handle"))
  }

  @Test func nonYouTubeHostsAreRejected() {
    #expect(YouTubeLink(string: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
    #expect(YouTubeLink(string: "https://notyoutube.com/watch?v=dQw4w9WgXcQ") == nil)
    #expect(YouTubeLink(string: "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ") == nil)
    #expect(YouTubeLink(string: "https://www.youtube.com/") == nil)
    #expect(YouTubeLink(string: "https://www.youtube.com/results?search_query=cats") == nil)
  }

  @Test func invalidVideoIDIsRejected() {
    #expect(YouTubeLink(string: "https://www.youtube.com/watch?v=short") == nil)
    #expect(YouTubeLink(string: "https://youtu.be/not!valid") == nil)
  }

  // MARK: Custom scheme (`youtube://`)

  @Test func schemeWatchURL() {
    #expect(YouTubeLink(string: "youtube://watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func schemeWithDomainHost() {
    #expect(YouTubeLink(string: "youtube://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "youtube://youtu.be/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func vndYouTubeScheme() {
    #expect(YouTubeLink(string: "vnd.youtube://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func schemePlaylistAndPathForms() {
    #expect(YouTubeLink(string: "youtube://playlist?list=PLabcdef123456") == .playlist(id: "PLabcdef123456"))
    #expect(YouTubeLink(string: "youtube://shorts/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "youtube://channel/UC1234567890abcdefghij") == .channel(id: "UC1234567890abcdefghij"))
    #expect(YouTubeLink(string: "youtube://v/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func unrelatedSchemesAreRejected() {
    #expect(YouTubeLink(string: "https://open.spotify.com/track/123") == nil)
    #expect(YouTubeLink(string: "mailto:someone@example.com") == nil)
    #expect(YouTubeLink(string: "random words without a url") == nil)
    #expect(YouTubeLink(string: "   ") == nil)
  }

  // MARK: Bare pasted text

  @Test func schemelessPastedLinks() {
    #expect(YouTubeLink(string: "youtu.be/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
    #expect(YouTubeLink(string: "youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
  }

  @Test func plainSearchTextIsNotALink() {
    #expect(YouTubeLink(string: "how to make pasta") == nil)
    #expect(YouTubeLink(string: "apple.com") == nil)
    #expect(YouTubeLink(string: "cats") == nil)
  }
}
