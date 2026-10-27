import MioTubeCore
import SwiftUI

struct ChannelView: View {
  let channelID: String
  let title: String
  @State private var tab: ChannelTabKind = .videos
  @State private var models: [ChannelTabKind: FeedModel]

  init(channelID: String, title: String) {
    self.channelID = channelID
    self.title = title
    _models = State(initialValue: Dictionary(uniqueKeysWithValues: Self.tabs.map { ($0, FeedModel(key: .channel(channelID, $0))) }))
  }

  static let tabs: [ChannelTabKind] = [.videos, .live, .playlists]

  var body: some View {
    let model = models[tab]!
    FeedScrollView(model: model) {
      ChannelHeader(header: model.page?.header ?? models[.videos]?.page?.header, fallbackTitle: title)
      Picker("Section", selection: $tab) {
        ForEach(Self.tabs, id: \.self) { kind in
          Text(kind.rawValue).tag(kind)
        }
      }
      .pickerStyle(.segmented)
    }
    .id(tab)
    .navigationTitle(model.page?.header?.title ?? title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
struct ChannelHeader: View {
  let header: FeedHeader?
  let fallbackTitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let banner = header?.bannerURL {
        RemoteImage(url: banner)
          .aspectRatio(6.2, contentMode: .fit)
          .clipShape(.rect(cornerRadius: 12))
      }
      HStack(spacing: 14) {
        RemoteImage(url: header?.avatarURL)
          .frame(width: 72, height: 72)
          .clipShape(.circle)
        VStack(alignment: .leading, spacing: 4) {
          Text(header?.title ?? fallbackTitle).font(.title2.weight(.bold))
          if let subtitle = header?.subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
      }
    }
  }
}
