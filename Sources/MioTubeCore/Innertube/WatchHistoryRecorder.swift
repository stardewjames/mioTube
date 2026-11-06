import Foundation

/// Records an actual playback in the signed-in YouTube account's watch history.
/// The playback URL must come from an authenticated WEB player response, not the
/// anonymous Apple-client response used to resolve the video stream.
public struct WatchHistoryRecorder: Sendable {
  public let client: InnertubeClient

  public init(client: InnertubeClient) {
    self.client = client
  }

  public func record(videoID: String, position: Double = 0, session expectedSession: GoogleSession) async throws {
    guard let session = await client.session.current(), session.hasAuthCookie, session.expiresAt > Date() else {
      throw MioTubeError.notSignedIn
    }
    guard session.hasSameIdentity(as: expectedSession) else { throw CancellationError() }
    let profile = client.catalog.metadata
    let config = await client.config?.config(session: session)
    let player = try await client.post(
      "player", StreamResolver.playerBody(videoID: videoID, profileID: profile.id), expectedSession: session
    )
    // An account switch during metadata loading must never write to the replacement account.
    guard let current = await client.session.current(), current.hasSameIdentity(as: session),
          current.expiresAt > Date()
    else { throw CancellationError() }
    try Task.checkCancellation()
    let request = try Self.makeRequest(
      player: player, videoID: videoID, session: current, profile: profile,
      clientVersion: config?.clientVersion ?? profile.clientVersion, nonce: Self.nonce(),
      position: position, config: config
    )
    do {
      _ = try await client.transport.send(request)
    } catch MioTubeError.http(let status, _) where status == 401 {
      throw MioTubeError.unauthorized
    }
  }

  static func makeRequest(
    player: JSONValue, videoID: String, session: GoogleSession, profile: ClientProfile,
    clientVersion: String, nonce: String, position: Double = 0, config: InnertubeConfig? = nil
  ) throws -> HTTPRequest {
    guard let raw = player["playbackTracking", "videostatsPlaybackUrl", "baseUrl"]?.string,
          var url = URLComponents(string: raw), url.scheme == "https",
          ["s.youtube.com", "www.youtube.com"].contains(url.host?.lowercased() ?? ""),
          url.port == nil || url.port == 443, url.user == nil, url.password == nil,
          url.path == "/api/stats/playback",
          url.queryItems?.filter({ $0.name == "docid" }).map(\.value) == [videoID]
    else { throw MioTubeError.invalidResponse("YouTube did not return a valid watch-history URL") }
    guard position.isFinite, position >= 0 else {
      throw MioTubeError.invalidResponse("Invalid watch-history playback position")
    }
    guard let token = config?.xsrfToken, !token.isEmpty else {
      throw MioTubeError.invalidResponse("YouTube did not return a watch-history session token")
    }
    guard let authorization = SapisidAuth.header(
      cookies: session.cookies, userSessionID: session.userSessionID ?? config?.userSessionID
    ) else {
      throw MioTubeError.notSignedIn
    }
    // Keep this same-origin so the account cookies authenticate the history write.
    url.host = "www.youtube.com"
    let parameters = [
      "ver": "2", "c": profile.clientName, "cver": clientVersion,
      "cpn": nonce, "cmt": String(position),
    ]
    var query = (url.percentEncodedQuery ?? "").split(separator: "&").filter {
      let name = $0.split(separator: "=", maxSplits: 1).first.map(String.init)?.removingPercentEncoding ?? ""
      return parameters[name] == nil
    }.map(String.init)
    var additions = URLComponents()
    additions.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
    query.append(additions.percentEncodedQuery ?? "")
    url.percentEncodedQuery = query.joined(separator: "&")
    url.fragment = nil
    guard let target = url.url else { throw MioTubeError.invalidResponse("Invalid watch-history URL") }
    var headers = [
      "Cookie": CookieJar.headerValue(session.cookies), "Authorization": authorization,
      "Origin": "https://www.youtube.com", "Referer": "https://www.youtube.com/watch?v=\(videoID)",
      "Content-Type": "application/x-www-form-urlencoded",
      "X-YouTube-Client-Name": String(profile.clientNameHeader),
      "X-YouTube-Client-Version": clientVersion,
    ]
    if let index = session.accountIndex ?? config?.accountIndex {
      headers["X-Goog-AuthUser"] = String(index)
    }
    if let pageID = session.delegatedSessionID ?? config?.delegatedSessionID {
      headers["X-Goog-PageId"] = pageID
    }
    if let loggedIn = config?.loggedIn {
      headers["X-Youtube-Bootstrap-Logged-In"] = loggedIn ? "true" : "false"
    }
    if let userAgent = profile.httpUserAgent { headers["User-Agent"] = userAgent }
    guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: Self.formCharacters) else {
      throw MioTubeError.invalidResponse("Invalid watch-history session token")
    }
    let body = Data("session_token=\(encodedToken)".utf8)
    // A history mutation: never replay it through the transport's retry policy.
    return HTTPRequest(method: .post, url: target, headers: headers, body: body, retryable: false)
  }

  private static let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
  private static let formCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")

  private static func nonce() -> String {
    var random = SystemRandomNumberGenerator()
    return String((0..<16).map { _ in nonceAlphabet[Int.random(in: 0..<nonceAlphabet.count, using: &random)] })
  }
}
