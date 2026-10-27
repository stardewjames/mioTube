import MioTubeCore
import SwiftUI

struct SubscriptionsView: View {
  @Environment(AppEnvironment.self) private var env
  @State private var model = FeedModel(key: .subscriptions)

  var body: some View {
    NavigationStack {
      Group {
        if env.account.isSignedIn {
          FeedScrollView(model: model)
        } else {
          SignInRequiredView(
            title: "Your subscriptions",
            message: "Sign in to see new videos from channels you follow.",
            systemImage: "play.square.stack"
          )
        }
      }
      .navigationTitle("Subscriptions")
      .toolbar { AccountToolbarItem() }
      .withRoutes()
    }
  }
}

struct SignInRequiredView: View {
  let title: String
  let message: String
  let systemImage: String
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(env.account.state == .expired ? "Session expired — sign in again" : message)
    } actions: {
      Button("Sign in") { env.account.isPresentingSignIn = true }
        .buttonStyle(.glassProminent)
    }
  }
}
