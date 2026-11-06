import MioTubeCore
import Observation
import SwiftUI

@Observable
final class LiveChatModel {
  enum Status: Equatable {
    case loading, live, unavailable, ended, failed(String)
  }

  private(set) var status: Status = .loading
  private(set) var session = LiveChatSession()
  @ObservationIgnored private var videoID: String?
  @ObservationIgnored private var generation = UUID()

  /// Owned by the visible view's task: hiding chat or leaving the foreground cancels polling.
  func watch(videoID: String, client: InnertubeClient) async {
    let generation = UUID()
    self.generation = generation
    if self.videoID != videoID {
      session.reset()
      self.videoID = videoID
    }
    status = .loading
    do {
      let next = try await client.post("next", ["videoId": .string(videoID)])
      guard !Task.isCancelled, self.generation == generation else { return }
      guard var token = LiveChatParser.initialContinuation(in: next) else {
        status = .unavailable
        return
      }
      while !Task.isCancelled {
        let json = try await client.post("live_chat/get_live_chat", [
          "continuation": .string(token),
          // Polling belongs to the visible, active view; hidden views cancel their task.
          "webClientInfo": ["isDocumentHidden": false],
        ])
        guard !Task.isCancelled, self.generation == generation else { return }
        guard json["continuationContents", "liveChatContinuation"] != nil else {
          throw MioTubeError.invalidResponse("YouTube did not return live chat data")
        }
        let page = LiveChatParser.parse(json)
        session.apply(page)
        guard let continuation = page.continuation else {
          status = .ended
          return
        }
        token = continuation
        status = .live
        // Preserve positive server pacing, including short bursts and long invalidation timeouts.
        // The parser supplies a paced default for missing or nonpositive delays.
        try await Task.sleep(for: .milliseconds(page.pollIntervalMilliseconds))
      }
    } catch {
      guard !Task.isCancelled, self.generation == generation else { return }
      status = .failed(FeedModel.describe(error))
    }
  }
}

/// Inline beneath the video, so reading chat never covers playback with a modal sheet.
struct LiveChatView: View {
  let videoID: String
  @Environment(AppEnvironment.self) private var env
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = LiveChatModel()
  @State private var following = true
  @State private var attempt = 0

  nonisolated private struct PollIdentity: Equatable {
    let videoID: String
    let attempt: Int
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Live chat").font(.headline)
          Text("Read-only · Messages are live, even during DVR playback")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button {
          following.toggle()
        } label: {
          Image(systemName: following ? "pause.circle" : "arrow.down.to.line.circle")
            .font(.title2)
        }
        .accessibilityLabel(following ? "Pause automatic scrolling" : "Follow live chat")
        .accessibilityValue(following ? "Following live chat" : "Automatic scrolling paused")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(model.session.messages) { message in
              LiveChatRow(message: message)
            }
            statusView
            Color.clear.frame(height: 1).id("chat-bottom")
          }
          .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: model.session.messages) {
          if following { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
        .onScrollPhaseChange { _, phase in
          if phase == .interacting { following = false }
        }
        .onChange(of: following) {
          if following { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
      }
    }
    .task(id: PollIdentity(videoID: videoID, attempt: scenePhase == .active ? attempt : -1)) {
      guard scenePhase == .active else { return }
      await model.watch(videoID: videoID, client: env.client)
    }
  }

  @ViewBuilder
  private var statusView: some View {
    switch model.status {
    case .loading:
      ProgressView("Connecting to live chat…").frame(maxWidth: .infinity)
    case .live:
      if model.session.messages.isEmpty {
        Text("Waiting for messages…").foregroundStyle(.secondary)
      }
    case .unavailable:
      ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right", description: Text("Live chat is disabled or unavailable for this stream."))
    case .ended:
      Label("Live chat has ended", systemImage: "checkmark.circle").foregroundStyle(.secondary)
    case .failed(let error):
      VStack(alignment: .leading, spacing: 8) {
        Text(error).font(.subheadline).foregroundStyle(.secondary)
        Button("Reconnect", systemImage: "arrow.clockwise") { attempt += 1 }
          .buttonStyle(.bordered)
      }
    }
  }
}

private struct LiveChatRow: View {
  let message: LiveChatMessage

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      RemoteImage(url: message.avatarURL)
        .frame(width: 28, height: 28)
        .clipShape(.circle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(message.author).font(.caption.weight(.semibold))
          if let timestamp = message.timestampText {
            Text(timestamp).font(.caption2).foregroundStyle(.secondary)
          }
        }
        if !message.badges.isEmpty {
          Text(message.badges.joined(separator: " · "))
            .font(.caption2).foregroundStyle(.secondary)
        }
        if let amount = message.purchaseAmount {
          Label(amount, systemImage: "gift.fill")
            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
        }
        if let stickerURL = message.stickerURL {
          RemoteImage(url: stickerURL)
            .frame(width: 96, height: 96)
            .accessibilityLabel(message.text)
        }
        Text(message.text).font(.subheadline).textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(message.purchaseAmount == nil ? 0 : 10)
    .background(message.purchaseAmount == nil ? Color.clear : Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 10))
  }
}
