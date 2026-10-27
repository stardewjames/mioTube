import MioTubeCore
import SwiftUI

struct PlaylistView: View {
  let playlistID: String
  let title: String
  @Environment(AppEnvironment.self) private var env
  @State private var model: FeedModel

  init(playlistID: String, title: String) {
    self.playlistID = playlistID
    self.title = title
    _model = State(initialValue: FeedModel(key: .playlist(playlistID)))
  }

  var body: some View {
    FeedScrollView(model: model, style: .list) {
      if let videos = model.page?.videos, let first = videos.first {
        HStack(spacing: 12) {
          Button {
            env.coordinator.play(first, queue: videos)
          } label: {
            Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity)
          }
          .buttonStyle(.glassProminent)
          Button {
            let shuffled = videos.shuffled()
            env.coordinator.play(shuffled[0], queue: shuffled)
          } label: {
            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
        }
        .controlSize(.large)
      }
    }
    .navigationTitle(model.page?.header?.title ?? title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
