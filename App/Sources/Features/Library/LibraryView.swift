import MioTubeCore
import SwiftUI

struct LibraryView: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    NavigationStack {
      List {
        Section {
          AccountSummaryRow()
        }
        if env.account.isSignedIn {
          Section("You") {
            NavigationLink(value: Route.feed(.history, title: "History")) {
              Label("History", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink(value: Route.playlist(id: "WL", title: "Watch later")) {
              Label("Watch later", systemImage: "clock")
            }
            NavigationLink(value: Route.playlist(id: "LL", title: "Liked videos")) {
              Label("Liked videos", systemImage: "hand.thumbsup")
            }
            NavigationLink(value: Route.feed(.library, title: "Playlists")) {
              Label("Playlists", systemImage: "list.and.film")
            }
          }
        } else {
          Section {
            Text("Sign in to see your history, playlists and liked videos.")
              .foregroundStyle(.secondary)
          }
        }
        if !env.coordinator.queue.isEmpty {
          Section("Queue") {
            ForEach(env.coordinator.queue) { item in
              Button {
                env.coordinator.jump(to: item)
                env.coordinator.isWatchPresented = true
              } label: {
                VideoRow(video: item.video)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .navigationTitle("Library")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink(value: Route.settings) {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
      .withRoutes()
    }
  }
}

struct AccountSummaryRow: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    HStack(spacing: 14) {
      RemoteImage(url: env.account.avatarURL)
        .frame(width: 48, height: 48)
        .clipShape(.circle)
        .overlay {
          if env.account.avatarURL == nil {
            Image(systemName: "person.fill").foregroundStyle(.secondary)
          }
        }
      VStack(alignment: .leading, spacing: 2) {
        switch env.account.state {
        case .signedIn, .validating:
          Text(env.account.name ?? "Signed in").font(.headline)
          Text("YouTube account").font(.caption).foregroundStyle(.secondary)
        case .expired:
          Text(env.account.name ?? "Account").font(.headline)
          Text("Session expired — sign in again").font(.caption).foregroundStyle(.orange)
        case .signedOut:
          Text("Not signed in").font(.headline)
          Text("Ad-free either way").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if env.account.state == .signedOut || env.account.state == .expired {
        Button("Sign in") { env.account.isPresentingSignIn = true }
          .buttonStyle(.glassProminent)
      }
    }
  }
}
