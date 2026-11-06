import MioTubeCore
import SwiftUI

struct WatchInfoPanel: View {
  @Environment(AppEnvironment.self) private var env
  @State private var descriptionExpanded = false
  @State private var showingComments = false
  @State private var likeOverride: LikeStatus?
  @State private var subscribedOverride: Bool?
  @State private var actionError: String?
  @State private var isUpdatingLike = false
  @State private var isUpdatingSubscription = false
  @State private var showingPlaylists = false
  @State private var draggedQueueID: QueueItem.ID?

  private var coordinator: PlaybackCoordinator { env.coordinator }

  var body: some View {
    if let info = coordinator.info {
      VStack(alignment: .leading, spacing: 16) {
        header(info)
        if let error = coordinator.historyError {
          Text(error).font(.caption).foregroundStyle(.secondary)
        }
        if let error = coordinator.captionError {
          Text(error).font(.caption).foregroundStyle(.secondary)
        }
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
        actionError = nil
      }
      .onChange(of: env.sessionRevision) {
        likeOverride = nil
        subscribedOverride = nil
        actionError = nil
        showingPlaylists = false
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
        .disabled(isUpdatingLike || coordinator.phase == .resolving)
        Button {
          setLike(like == .dislike ? .none : .dislike, info: info)
        } label: {
          Label("Dislike", systemImage: like == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        }
        .disabled(!signedIn || isUpdatingLike || coordinator.phase == .resolving)
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
            .disabled(isUpdatingSubscription || coordinator.phase == .resolving)
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
          Button { coordinator.jump(to: item) } label: {
            VideoRow(video: item.video, progress: env.watchProgress.entry(for: item.video.videoID))
          }
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
            VideoRow(video: video, progress: env.watchProgress.entry(for: video.videoID)).equatable()
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
    guard !isUpdatingLike, coordinator.phase != .resolving else { return }
    let current = likeOverride ?? info.likeStatus
    let params = switch status {
    case .like: info.likeParams
    case .dislike: info.dislikeParams
    case .none: current == .dislike ? info.removeDislikeParams : info.removeLikeParams
    }
    isUpdatingLike = true
    let accountRevision = env.sessionRevision
    Task {
      defer { isUpdatingLike = false }
      do {
        try await env.actions.setLike(status, videoID: info.videoID, params: params)
        if env.sessionRevision == accountRevision, coordinator.info?.videoID == info.videoID { likeOverride = status }
      } catch {
        guard env.sessionRevision == accountRevision, coordinator.info?.videoID == info.videoID else { return }
        actionError = FeedModel.describe(error)
      }
    }
  }

  private func toggleSubscription(_ state: SubscribeState, currentlySubscribed: Bool) {
    guard !isUpdatingSubscription, coordinator.phase != .resolving else { return }
    isUpdatingSubscription = true
    let accountRevision = env.sessionRevision
    Task {
      defer { isUpdatingSubscription = false }
      do {
        try await env.actions.setSubscribed(
          !currentlySubscribed, channelID: state.channelID,
          params: currentlySubscribed ? state.unsubscribeParams : state.params
        )
        if env.sessionRevision == accountRevision, coordinator.info?.subscribe?.channelID == state.channelID {
          subscribedOverride = !currentlySubscribed
        }
      } catch {
        guard env.sessionRevision == accountRevision, coordinator.info?.subscribe?.channelID == state.channelID else { return }
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
  @State private var isUpdating = false

  var body: some View {
    NavigationStack {
      List {
        if let error {
          Text(error).foregroundStyle(.red)
        }
        ForEach(options) { option in
          Button {
            Task {
              guard !isUpdating else { return }
              isUpdating = true
              defer { isUpdating = false }
              do {
                try await env.actions.setPlaylistMembership(!option.containsVideo, option: option)
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
          .disabled(isUpdating)
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
