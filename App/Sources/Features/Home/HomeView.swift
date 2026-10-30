import MioTubeCore
import SwiftUI

struct HomeView: View {
  @Environment(AppEnvironment.self) private var env
  @State private var model = FeedModel(key: .home)

  var body: some View {
    @Bindable var env = env
    NavigationStack(path: $env.homePath) {
      FeedScrollView(model: model) {
        if env.account.state == .expired {
          SessionExpiredBanner()
        } else if !env.account.isSignedIn, let notice = model.page?.notice {
          SignInBanner(message: notice)
        }
      }
      .navigationTitle("Home")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { AccountToolbarItem() }
      .withRoutes()
    }
  }
}

/// Glass banner offering sign-in on the signed-out fallback home.
struct SignInBanner: View {
  let message: String
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    GlassPanel {
      HStack(spacing: 12) {
        Image(systemName: "sparkles.tv").font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text("Showing popular videos").font(.subheadline.weight(.semibold))
          Text("\(message). Sign in for your recommendations.").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("Sign in") { env.account.isPresentingSignIn = true }
          .buttonStyle(.glassProminent)
      }
      .padding(14)
    }
  }
}

struct SessionExpiredBanner: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    GlassPanel {
      HStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text("Session expired — sign in again").font(.subheadline.weight(.semibold))
        Spacer(minLength: 8)
        Button("Sign in") { env.account.isPresentingSignIn = true }
          .buttonStyle(.glassProminent)
      }
      .padding(14)
    }
  }
}

/// Avatar / sign-in button shown in tab toolbars.
struct AccountToolbarItem: ToolbarContent {
  @Environment(AppEnvironment.self) private var env

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      if env.account.isSignedIn {
        NavigationLink(value: Route.settings) {
          RemoteImage(url: env.account.avatarURL)
            .frame(width: 30, height: 30)
            .clipShape(.circle)
        }
        .accessibilityLabel("Account and settings")
      } else {
        Button {
          env.account.isPresentingSignIn = true
        } label: {
          Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Sign in")
      }
    }
  }
}
