import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MioTubeCore

@Suite struct HTTPRedirectTests {
  @Test func credentialsCannotCrossHostSchemeOrPortBoundaries() {
    let targets = [
      "https://www.youtube.com.attacker.test/api/stats/playback",
      "http://www.youtube.com/api/stats/playback",
      "https://www.youtube.com:444/api/stats/playback",
    ]
    for header in ["Cookie", "Authorization", "X-Goog-Visitor-Id"] {
      for target in targets {
        #expect(redirectAllowed(to: target, headers: [header: "private-session"]) == false)
      }
    }
  }

  @Test func sameOriginRedirectPreservesAuthenticatedRequest() {
    #expect(redirectAllowed(
      to: "https://www.youtube.com:443/another-path", headers: ["Cookie": "SAPISID=private"]
    ) == true)
  }

  @Test func anonymousCDNReadMayRedirectButPostCannotChangeOrigin() {
    let target = "https://cdn.example.test/resource"
    #expect(redirectAllowed(to: target) == true)
    // A 302 can turn a POST into a GET; the original method must still protect the write.
    #expect(redirectAllowed(to: target, originalMethod: "POST") == false)
  }

  private func redirectAllowed(
    to target: String, headers: [String: String] = [:], originalMethod: String = "GET"
  ) -> Bool? {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let source = URL(string: "https://www.youtube.com/api/stats/playback")!
    var original = URLRequest(url: source)
    original.httpMethod = originalMethod
    original.allHTTPHeaderFields = headers
    // Never resumed: this exercises the actual delegate without contacting any server.
    let task = session.dataTask(with: original)
    var redirected = URLRequest(url: URL(string: target)!)
    redirected.httpMethod = "GET"
    let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
    let decision = RedirectDecision()
    CredentialRedirectGuard().urlSession(
      session, task: task, willPerformHTTPRedirection: response, newRequest: redirected
    ) { decision.set($0 != nil) }
    return decision.get()
  }
}

private final class RedirectDecision: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?

  func set(_ value: Bool) { lock.withLock { self.value = value } }
  func get() -> Bool? { lock.withLock { value } }
}
