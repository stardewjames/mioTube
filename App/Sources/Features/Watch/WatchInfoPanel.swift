import MioTubeCore
import SwiftUI

struct WatchInfoPanel: View {
  @Environment(AppEnvironment.self) private var env
  @State private var descriptionExpanded = false
  @State private var showingComments = false
  @State private var likeOverride: LikeStatus?
  @State private var subscribedOverride: Bool?
  @State private var actionError: String?
  @State private var showingPlaylists = false
  @State private var draggedQueueID: QueueItem.ID?

  private var coordinator: PlaybackCoordinator { env.coordinator }

  var body: some View {
    if let info = coordinator.info {
      VStack(alignment: .leading, spacing: 16) {
        header(info)
        actions(info)
        channelRow(info)
        description(info)
        if !info.chapters.isEmpty { chapters(info) }
        if info.commentsContinuation != nil { commentsEntry(info) }
        upNext(info)
      }
      .id(info.videoID)
      .sheet(isPresented: $showingComments) {
        if let token = info.commentsContinuation {
          CommentsView(initialToken: token, countText: info.commentsCountText)
        }
      }
      .sheet(isPresented: $showingPlaylists) {
        AddToPlaylistSheet(videoID: info.videoID)
      }
      .alert("Couldn't update", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(actionError ?? "")
      }
      .onChange(of: info.videoID) {
        likeOverride = nil
        subscribedOverride = nil
        descriptionExpanded = false
      }
    }
  }

  // MARK: Sections

  private func header(_ info: WatchInfo) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(info.title).font(.title3.weight(.bold))
      HStack(spacing: 8) {
        Text(Format.metadataLine(info.viewCountText, info.publishedText))
          .font(.caption)
          .foregroundStyle(.secondary)
        if info.isLive { LiveBadge() }
        if coordinator.fullVideoSponsored {
          Label("Sponsored", systemImage: "dollarsign.circle.fill")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.25), in: .capsule)
        }
      }
    }
  }

  private func actions(_ info: WatchInfo) -> some View {
    let like = likeOverride ?? info.likeStatus
    let signedIn = env.account.isSignedIn
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        Button {
          setLike(like == .like ? .none : .like, info: info)
        } label: {
          Label(signedIn ? (info.likeCountText ?? "Like") : "Sign in to like", systemImage: like == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
        }
        Button {
          setLike(like == .dislike ? .none : .dislike, info: info)
        } label: {
          Label("Dislike", systemImage: like == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        }
        .disabled(!signedIn)
        ShareLink(item: URL(string: "https://youtu.be/\(info.videoID)")!) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        Button {
          showingPlaylists = true
        } label: {
          Label("Save", systemImage: "text.badge.plus")
        }
        .disabled(!signedIn)
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .font(.subheadline)
    }
  }

  @ViewBuilder
  private func channelRow(_ info: WatchInfo) -> some View {
    if let channel = info.channel {
      HStack(spacing: 12) {
        NavigationLink(value: Route.channel(id: channel.channelID, title: channel.title)) {
          HStack(spacing: 12) {
            RemoteImage(url: channel.thumbnailURL)
              .frame(width: 40, height: 40)
              .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
              Text(channel.title).font(.subheadline.weight(.semibold))
              if let subs = channel.subscriberText {
                Text(subs).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        .buttonStyle(.plain)
        Spacer()
        if let subscribe = info.subscribe {
          let subscribed = subscribedOverride ?? subscribe.isSubscribed
          if env.account.isSignedIn {
            Button(subscribed ? "Subscribed" : "Subscribe") {
              toggleSubscription(subscribe, currentlySubscribed: subscribed)
            }
            .buttonStyle(.borderedProminent)
            .tint(subscribed ? Color(.systemGray3) : .red)
            .buttonBorderShape(.capsule)
          } else {
            Button("Sign in to subscribe") { env.account.isPresentingSignIn = true }
              .buttonStyle(.bordered)
              .buttonBorderShape(.capsule)
              .font(.caption)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func description(_ info: WatchInfo) -> some View {
    if !info.description.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(info.description)
          .font(.subheadline)
          .lineLimit(descriptionExpanded ? nil : 3)
          .textSelection(.enabled)
        Button(descriptionExpanded ? "Show less" : "Show more") {
          withAnimation { descriptionExpanded.toggle() }
        }
        .font(.caption.weight(.semibold))
      }
      .padding(12)
      .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }
  }

  private func chapters(_ info: WatchInfo) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(title: "Chapters")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(info.chapters, id: \.startSeconds) { chapter in
            Button {
              coordinator.engine.seek(to: chapter.startSeconds)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(Format.duration(chapter.startSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(chapter.title).font(.caption.weight(.semibold)).lineLimit(2)
              }
              .frame(width: 150, alignment: .leading)
              .padding(10)
              .background(
                Color(uiColor: coordinator.currentChapter == chapter ? UIColor.tertiarySystemFill : UIColor.secondarySystemBackground),
                in: .rect(cornerRadius: 10)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func commentsEntry(_ info: WatchInfo) -> some View {
    Button {
      showingComments = true
    } label: {
      HStack {
        Label("Comments", systemImage: "text.bubble")
          .font(.subheadline.weight(.semibold))
        if let count = info.commentsCountText {
          Text(count).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }
      .padding(12)
      .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }

  private func upNext(_ info: WatchInfo) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      let queued = Array(coordinator.queue.dropFirst(coordinator.index + 1))
      if !queued.isEmpty {
        SectionHeader(title: "Queue")
        ForEach(queued) { item in
          Button { coordinator.jump(to: item) } label: { VideoRow(video: item.video) }
            .buttonStyle(.plain)
            .modifier(SwipeToRemove { coordinator.removeFromQueue(item.id) })
            .queueReorder(id: item.id, dragged: $draggedQueueID, coordinator: coordinator)
        }
      }
      if !info.related.isEmpty {
        SectionHeader(title: "Up next")
        ForEach(info.related) { video in
          Button {
            coordinator.play(video, queue: [video], present: true)
          } label: {
            VideoRow(video: video).equatable()
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { coordinator.playNext(video) }
          }
        }
      }
    }
  }

  // MARK: Actions

  private func setLike(_ status: LikeStatus, info: WatchInfo) {
    guard env.account.isSignedIn else {
      env.account.isPresentingSignIn = true
      return
    }
    let previous = likeOverride
    likeOverride = status
    Task {
      do {
        try await env.actions.setLike(status, videoID: info.videoID)
      } catch {
        likeOverride = previous
        actionError = FeedModel.describe(error)
      }
    }
  }

  private func toggleSubscription(_ state: SubscribeState, currentlySubscribed: Bool) {
    subscribedOverride = !currentlySubscribed
    Task {
      do {
        try await env.actions.setSubscribed(!currentlySubscribed, channelID: state.channelID, params: state.params)
      } catch {
        subscribedOverride = currentlySubscribed
        actionError = FeedModel.describe(error)
      }
    }
  }
}

struct AddToPlaylistSheet: View {
  let videoID: String
  @Environment(AppEnvironment.self) private var env
  @Environment(\.dismiss) private var dismiss
  @State private var options: [PlaylistOption] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        if let error {
          Text(error).foregroundStyle(.red)
        }
        ForEach(options) { option in
          Button {
            Task {
              do {
                if option.containsVideo {
                  try await env.actions.removeFromPlaylist(videoID: videoID, playlistID: option.playlistID)
                } else {
                  try await env.actions.addToPlaylist(videoID: videoID, playlistID: option.playlistID)
                }
                await reload()
              } catch {
                self.error = FeedModel.describe(error)
              }
            }
          } label: {
            HStack {
              Text(option.title)
              Spacer()
              if option.containsVideo { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
          }
        }
      }
      .overlay { if loading { ProgressView() } }
      .navigationTitle("Save to playlist")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .task { await reload() }
    }
    .presentationDetents([.medium, .large])
  }

  private func reload() async {
    do {
      options = try await env.actions.playlistOptions(videoID: videoID)
      error = nil
    } catch {
      self.error = FeedModel.describe(error)
    }
    loading = false
  }
}
