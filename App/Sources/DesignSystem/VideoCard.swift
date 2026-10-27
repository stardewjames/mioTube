import MioTubeCore
import SwiftUI

enum Format {
  static func duration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  static func metadataLine(_ parts: String?...) -> String {
    parts.compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
  }
}

struct LiveBadge: View {
  var body: some View {
    Text("LIVE")
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.red, in: .rect(cornerRadius: 4))
      .foregroundStyle(.white)
  }
}

/// 16:9 thumbnail with duration pill / live badge.
struct VideoThumbnail: View {
  let video: VideoSummary
  var cornerRadius: CGFloat = 12

  var body: some View {
    RemoteImage(url: video.bestThumbnailURL)
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(.rect(cornerRadius: cornerRadius))
      .overlay(alignment: .bottomTrailing) {
        Group {
          if video.isLive {
            LiveBadge()
          } else if let seconds = video.durationSeconds {
            Text(Format.duration(Double(seconds)))
              .font(.caption2.weight(.semibold).monospacedDigit())
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.ultraThinMaterial, in: .rect(cornerRadius: 4))
          } else if video.isUpcoming {
            Text("UPCOMING")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.ultraThinMaterial, in: .rect(cornerRadius: 4))
          }
        }
        .padding(6)
      }
  }
}

/// Grid card: thumbnail, two-line title, channel + views line.
struct VideoCard: View, Equatable {
  let video: VideoSummary

  nonisolated static func == (lhs: VideoCard, rhs: VideoCard) -> Bool { lhs.video == rhs.video }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VideoThumbnail(video: video)
      Text(video.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .foregroundStyle(.primary)
      Text(Format.metadataLine(video.channelName, video.viewCountText, video.publishedText))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .contentShape(.rect)
  }
}

/// Compact row (search results, related, playlists): 160 pt thumbnail.
struct VideoRow: View, Equatable {
  let video: VideoSummary

  nonisolated static func == (lhs: VideoRow, rhs: VideoRow) -> Bool { lhs.video == rhs.video }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VideoThumbnail(video: video, cornerRadius: 8)
        .frame(width: 160)
      VStack(alignment: .leading, spacing: 4) {
        Text(video.title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .foregroundStyle(.primary)
        Text(video.channelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Text(Format.metadataLine(video.viewCountText, video.publishedText))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .contentShape(.rect)
  }
}

struct PlaylistCard: View {
  let playlist: PlaylistSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RemoteImage(url: playlist.thumbnailURL)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
          Label(playlist.videoCountText ?? "Playlist", systemImage: "list.and.film")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 4))
            .padding(6)
        }
      Text(playlist.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
      if !playlist.author.isEmpty {
        Text(playlist.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .contentShape(.rect)
  }
}

struct ChannelRow: View {
  let channel: ChannelSummary

  var body: some View {
    HStack(spacing: 14) {
      RemoteImage(url: channel.thumbnailURL)
        .frame(width: 64, height: 64)
        .clipShape(.circle)
      VStack(alignment: .leading, spacing: 2) {
        Text(channel.title).font(.headline).foregroundStyle(.primary)
        Text(Format.metadataLine(channel.handle, channel.subscriberText))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .contentShape(.rect)
  }
}

/// Shelf title row with optional trailing action.
struct SectionHeader: View {
  let title: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack {
      Text(title).font(.title3.weight(.bold))
      Spacer()
      if let actionTitle, let action {
        Button(actionTitle, action: action).font(.subheadline)
      }
    }
    .padding(.top, 8)
  }
}
