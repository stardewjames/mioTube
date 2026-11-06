import MioTubeCore
import SwiftUI
import WebKit

/// Google sign-in sheet. Uses a throwaway (non-persistent) data store; YouTube cookies are
/// captured once SAPISID appears and stored in the Keychain.
struct SignInSheet: View {
  @Environment(AppEnvironment.self) private var env
  @Environment(\.dismiss) private var dismiss
  @State private var useAlternateAgent = false
  @State private var reloadToken = 0

  var body: some View {
    NavigationStack {
      SignInWebView(userAgent: userAgent, reloadToken: reloadToken) { cookies, expiry in
        Task { await env.account.signIn(cookies: cookies, expiresAt: expiry) }
      }
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle("Sign in to YouTube")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button(useAlternateAgent ? "Use Safari (Mac) browser" : "Use iPad Safari browser") {
              useAlternateAgent.toggle()
              reloadToken += 1
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("Sign-in options")
        }
      }
    }
  }

  /// `web_safari` UA by default; `mweb` when Google rejects the first one.
  private var userAgent: String {
    let id = useAlternateAgent ? "mweb" : "web_safari"
    return env.catalog.profile(id)?.httpUserAgent ?? ""
  }
}

struct SignInWebView: UIViewRepresentable {
  let userAgent: String
  let reloadToken: Int
  let onSignedIn: ([String: String], Date) -> Void

  static let startURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!

  func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent = userAgent
    webView.navigationDelegate = context.coordinator
    context.coordinator.lastReload = reloadToken
    webView.load(URLRequest(url: Self.startURL))
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.lastReload != reloadToken else { return }
    context.coordinator.lastReload = reloadToken
    webView.customUserAgent = userAgent
    webView.load(URLRequest(url: Self.startURL))
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    let onSignedIn: ([String: String], Date) -> Void
    var lastReload = 0
    private var finished = false

    init(onSignedIn: @escaping ([String: String], Date) -> Void) {
      self.onSignedIn = onSignedIn
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard !finished, let host = webView.url?.host,
            GoogleSession.matchesDomain(host, root: "youtube.com") else { return }
      let store = webView.configuration.websiteDataStore.httpCookieStore
      Task { @MainActor in
        let cookies = await store.allCookies()
        guard let captured = Self.capture(cookies), !finished else { return }
        finished = true
        onSignedIn(captured.0, captured.1)
      }
    }

    /// YouTube-domain cookies plus the classic Google auth cookies; expiry = earliest auth
    /// cookie expiry (fallback now + 30 days).
    static func capture(_ cookies: [HTTPCookie]) -> ([String: String], Date)? {
      var selected: [String: HTTPCookie] = [:]
      let now = Date()
      for cookie in cookies {
        let domain = cookie.domain.lowercased()
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let isYouTube = host == "www.youtube.com" || (host == "youtube.com" && domain.hasPrefix("."))
        let isGoogleAuth = (host == "google.com")
          && GoogleSession.googleDomainCookieNames.contains(cookie.name)
        guard cookie.path == "/", isYouTube || isGoogleAuth,
              cookie.expiresDate.map({ $0 > now }) ?? true else { continue }
        if let existing = selected[cookie.name] {
          guard isYouTube else { continue }
          let existingHost = existing.domain.hasPrefix(".") ? String(existing.domain.dropFirst()) : existing.domain
          if existingHost == "www.youtube.com", host != existingHost { continue }
        }
        selected[cookie.name] = cookie
      }
      let result = selected.mapValues(\.value)
      let expiry = selected.values.reduce(nil as Date?) { earliest, cookie in
        guard GoogleSession.authCookieNames.contains(cookie.name), let date = cookie.expiresDate else { return earliest }
        return earliest.map { min($0, date) } ?? date
      } ?? now.addingTimeInterval(30 * 86_400)
      guard GoogleSession(cookies: result, expiresAt: expiry).hasAuthCookie else { return nil }
      return (result, expiry)
    }
  }
}

/// Settings → "Paste cookies" fallback for when Google blocks the embedded browser.
struct PasteCookiesView: View {
  @Environment(AppEnvironment.self) private var env
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var isWorking = false

  var body: some View {
    Form {
      Section {
        TextEditor(text: $text)
          .font(.footnote.monospaced())
          .frame(minHeight: 220)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      } footer: {
        Text("Paste a Cookie: header or a Netscape cookies.txt export from a signed-in youtube.com browser session. It is checked against YouTube before it is saved to the Keychain.")
      }
      if let error = env.account.lastError {
        Section { Text(error).foregroundStyle(.red) }
      }
      Section {
        Button {
          isWorking = true
          Task {
            let ok = await env.account.importCookies(text)
            isWorking = false
            if ok { dismiss() }
          }
        } label: {
          if isWorking { ProgressView() } else { Text("Validate and save") }
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
      }
    }
    .navigationTitle("Paste cookies")
  }
}
