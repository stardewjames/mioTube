import Foundation
import MioTubeCore
import Observation
import WebKit

@Observable
final class AccountViewModel {
  enum State: Equatable {
    case signedOut
    case validating
    case signedIn
    case expired
  }

  private(set) var state: State = .signedOut
  private(set) var name: String?
  private(set) var avatarURL: URL?
  var lastError: String?
  var isPresentingSignIn = false

  @ObservationIgnored private let store: KeychainSessionStore
  @ObservationIgnored private let actions: AccountActions
  @ObservationIgnored private let cache: FeedCache
  @ObservationIgnored var onSessionChange: (() -> Void)?

  init(store: KeychainSessionStore, actions: AccountActions, cache: FeedCache) {
    self.store = store
    self.actions = actions
    self.cache = cache
  }

  var isSignedIn: Bool { state == .signedIn || state == .validating }

  /// Launch check: restores the Keychain session and validates it in the background.
  func restore() async {
    guard let session = await store.current() else {
      state = .signedOut
      return
    }
    name = session.name
    avatarURL = session.avatarURL
    if session.expiresAt < Date() {
      state = .expired
      return
    }
    state = .validating
    await refresh()
  }

  /// Called by the sign-in web view with captured cookies.
  func signIn(cookies: [String: String], expiresAt: Date) async {
    let session = GoogleSession(cookies: cookies, expiresAt: expiresAt)
    guard session.hasAuthCookie else {
      lastError = "Sign-in did not produce YouTube credentials."
      return
    }
    await store.save(session)
    await cache.clearPersonal()
    state = .validating
    isPresentingSignIn = false
    await refresh()
    onSessionChange?()
  }

  /// "Paste cookies" fallback: `Cookie:` header or Netscape cookie file, validated with one
  /// `FEwhat_to_watch` request before it is kept.
  func importCookies(_ text: String) async -> Bool {
    let parsed = CookieJar.parse(text)
    let session = GoogleSession(
      cookies: parsed.cookies, expiresAt: parsed.earliestExpiry ?? Date().addingTimeInterval(30 * 86_400)
    )
    guard session.hasAuthCookie else {
      lastError = "No SAPISID cookie found."
      return false
    }
    let previous = await store.current()
    await store.save(session)
    do {
      try await actions.validateSession()
    } catch {
      await store.save(previous)
      lastError = (error as? MioTubeError) == .unauthorized ? "Those cookies are not signed in." : error.localizedDescription
      return false
    }
    await cache.clearPersonal()
    await refresh()
    onSessionChange?()
    return true
  }

  func signOut() async {
    await store.clear()
    await cache.clearPersonal()
    await WKWebsiteDataStore.default().removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
    )
    name = nil
    avatarURL = nil
    state = .signedOut
    onSessionChange?()
  }

  /// Validates the session (`FEwhat_to_watch` must come back signed in) and loads the
  /// account name/avatar. Never blocks UI.
  func refresh() async {
    guard var session = await store.current() else {
      state = .signedOut
      return
    }
    do {
      try await actions.validateSession()
      if let info = try? await actions.accountInfo() {
        name = info.name
        avatarURL = info.avatarURL
        session.name = info.name
        session.avatarURL = info.avatarURL
        await store.save(session)
      }
      state = .signedIn
    } catch MioTubeError.unauthorized {
      state = .expired
    } catch {
      // Offline or transient: keep the session, assume still valid.
      state = .signedIn
    }
  }

  func markExpired() {
    if state != .signedOut { state = .expired }
  }
}
