import MioTubeCore
import Observation
import SwiftUI

@Observable
final class CommentsModel {
  private(set) var comments: [Comment] = []
  private(set) var sortOptions: [CommentSortOption] = []
  private(set) var countText: String?
  private(set) var isLoading = false
  private(set) var error: String?
  @ObservationIgnored private var continuation: String?
  @ObservationIgnored private var seen = Set<String>()

  func load(_ token: String, client: InnertubeClient, reset: Bool) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let json = try await client.post("next", ["continuation": .string(token)])
      let page = CommentsParser.parse(json)
      if reset {
        comments = []
        seen = []
      }
      for comment in page.comments where seen.insert(comment.id).inserted {
        comments.append(comment)
      }
      if !page.sortOptions.isEmpty { sortOptions = page.sortOptions }
      if let count = page.countText { countText = count }
      continuation = page.continuation
      error = nil
    } catch {
      self.error = FeedModel.describe(error)
    }
  }

  func loadMore(client: InnertubeClient) async {
    guard let continuation else { return }
    self.continuation = nil
    await load(continuation, client: client, reset: false)
  }

  var hasMore: Bool { continuation != nil }
}

struct CommentsView: View {
  let initialToken: String
  let countText: String?
  @Environment(AppEnvironment.self) private var env
  @Environment(\.dismiss) private var dismiss
  @State private var model = CommentsModel()

  var body: some View {
    NavigationStack {
      List {
        if !model.sortOptions.isEmpty {
          Section {
            ScrollView(.horizontal, showsIndicators: false) {
              GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                  ForEach(model.sortOptions) { option in
                    Button(option.title == "Top" ? "Top comments" : option.title) {
                      Task { await model.load(option.token, client: env.client, reset: true) }
                    }
                    .buttonStyle(.glass)
                    .fontWeight(option.isSelected ? .semibold : .regular)
                  }
                }
              }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
          }
        }
        Section {
          ForEach(model.comments) { comment in
            CommentRow(comment: comment)
              .onAppear {
                if comment.id == model.comments.last?.id {
                  Task { await model.loadMore(client: env.client) }
                }
              }
          }
          if model.isLoading {
            ProgressView().frame(maxWidth: .infinity)
          } else if let error = model.error {
            Text(error).foregroundStyle(.secondary)
          } else if model.comments.isEmpty {
            Text("No comments").foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.plain)
      .navigationTitle(model.countText.map { "Comments · \($0)" } ?? countText.map { "Comments · \($0)" } ?? "Comments")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .task { await model.load(initialToken, client: env.client, reset: true) }
    }
    .presentationDetents([.medium, .large])
  }
}

struct CommentRow: View {
  let comment: Comment

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RemoteImage(url: comment.authorAvatarURL)
        .frame(width: 32, height: 32)
        .clipShape(.circle)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(comment.author)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, comment.isCreator ? 6 : 0)
            .background(comment.isCreator ? Color(.tertiarySystemFill) : .clear, in: .capsule)
          if let published = comment.publishedText {
            Text(published).font(.caption).foregroundStyle(.secondary)
          }
          if comment.isPinned {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
          }
        }
        Text(comment.text).font(.subheadline).textSelection(.enabled)
        HStack(spacing: 14) {
          if let likes = comment.likeCountText {
            Label(likes, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
          }
          if comment.replyCount > 0 {
            Text("\(comment.replyCount) replies").font(.caption.weight(.semibold)).foregroundStyle(.tint)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }
}
