import Foundation

public struct LiveChatMessage: Sendable, Hashable, Identifiable {
  public let id: String
  public let author: String
  public let authorChannelID: String?
  public let avatarURL: URL?
  public let text: String
  public let timestampText: String?
  public let badges: [String]
  public let purchaseAmount: String?
  public let stickerURL: URL?

  public init(
    id: String, author: String, authorChannelID: String? = nil, avatarURL: URL? = nil,
    text: String, timestampText: String? = nil, badges: [String] = [], purchaseAmount: String? = nil,
    stickerURL: URL? = nil
  ) {
    self.id = id
    self.author = author
    self.authorChannelID = authorChannelID
    self.avatarURL = avatarURL
    self.text = text
    self.timestampText = timestampText
    self.badges = badges
    self.purchaseAmount = purchaseAmount
    self.stickerURL = stickerURL
  }
}

public struct LiveChatPage: Sendable {
  /// Parsed additions and replacements. Apply the page to a session to include moderation and ordering.
  public let messages: [LiveChatMessage]
  /// Nil means live polling has ended; replay continuations are never returned.
  public let continuation: String?
  public let pollIntervalMilliseconds: Int

  // Message indices share the public payload without retaining a second copy of every row.
  enum Mutation: Sendable {
    case add(Int)
    case replace(targetID: String, messageIndex: Int)
    case remove(String)
    case removeAuthor(String)
  }

  let mutations: [Mutation]
}

public enum LiveChatParser {
  /// Only inspect the chat renderer's own live continuations, never comments, menus, or replay tokens.
  public static func initialContinuation(in next: JSONValue) -> String? {
    guard let renderer = RendererTree.first("liveChatRenderer", in: next),
          renderer["isReplay"]?.bool != true
    else { return nil }
    return liveContinuation(in: renderer)?.token
  }

  public static func parse(_ json: JSONValue) -> LiveChatPage {
    guard let chat = json["continuationContents", "liveChatContinuation"],
          chat["isReplay"]?.bool != true
    else {
      return LiveChatPage(messages: [], continuation: nil, pollIntervalMilliseconds: 5_000, mutations: [])
    }

    var messages: [LiveChatMessage] = []
    var mutations: [LiveChatPage.Mutation] = []
    for item in chat["items"]?.array ?? [] {
      if let message = message(in: item) {
        mutations.append(.add(messages.count))
        messages.append(message)
      }
    }
    for action in chat["actions"]?.array ?? [] {
      // Do not descend into action payloads: replay and ticker actions contain duplicate chat items.
      if let add = action["addChatItemAction"], let message = message(in: add["item"]) {
        mutations.append(.add(messages.count))
        messages.append(message)
      } else if let replace = action["replaceChatItemAction"],
                let target = nonempty(replace["targetItemId"]?.string),
                let message = message(in: replace["replacementItem"]) {
        mutations.append(.replace(targetID: target, messageIndex: messages.count))
        messages.append(message)
      } else if let remove = action["removeChatItemAction"] ?? action["markChatItemAsDeletedAction"],
                let target = nonempty(remove["targetItemId"]?.string) {
        mutations.append(.remove(target))
      } else if let remove = action["removeChatItemByAuthorAction"] ?? action["markChatItemsByAuthorAsDeletedAction"],
                let author = nonempty(remove["externalChannelId"]?.string) {
        mutations.append(.removeAuthor(author))
      }
    }
    let continuation = liveContinuation(in: chat)
    return LiveChatPage(
      messages: messages, continuation: continuation?.token,
      pollIntervalMilliseconds: continuation?.milliseconds ?? 5_000, mutations: mutations
    )
  }

  private static func liveContinuation(in chat: JSONValue) -> (token: String, milliseconds: Int)? {
    for entry in chat["continuations"]?.array ?? [] {
      for key in ["timedContinuationData", "invalidationContinuationData", "reloadContinuationData"] {
        guard let data = entry[key], let token = nonempty(data["continuation"]?.string) else { continue }
        // Missing and nonpositive delays use a paced default; positive server delays are preserved.
        let milliseconds = data["timeoutMs"]?.int ?? 5_000
        return (token, milliseconds > 0 ? milliseconds : 5_000)
      }
    }
    return nil
  }

  private static func message(in item: JSONValue?) -> LiveChatMessage? {
    guard let item else { return nil }
    for key in [
      "liveChatTextMessageRenderer", "liveChatPaidMessageRenderer",
      "liveChatPaidStickerRenderer", "liveChatMembershipItemRenderer",
    ] {
      guard let renderer = item[key], let id = nonempty(renderer["id"]?.string) else { continue }
      var text = richText(renderer["message"]) ?? ""
      if key == "liveChatMembershipItemRenderer" {
        var parts: [String] = []
        for value in [renderer["headerPrimaryText"], renderer["headerSubtext"], renderer["message"]] {
          if let part = richText(value), !parts.contains(part) { parts.append(part) }
        }
        text = parts.joined(separator: "\n")
      } else if key == "liveChatPaidStickerRenderer", text.isEmpty {
        text = accessibilityLabel(renderer["sticker"]) ?? ""
      }
      var badges: [String] = []
      for badge in renderer["authorBadges"]?.array ?? [] {
        guard let badge = badge["liveChatAuthorBadgeRenderer"],
              let label = accessibilityLabel(badge) ?? nonempty(badge["tooltip"]?.string),
              !badges.contains(label)
        else { continue }
        badges.append(label)
      }
      return LiveChatMessage(
        id: id, author: richText(renderer["authorName"]) ?? "",
        authorChannelID: nonempty(renderer["authorExternalChannelId"]?.string),
        avatarURL: renderer["authorPhoto"]?.firstThumbnailURL(), text: text,
        timestampText: richText(renderer["timestampText"]), badges: badges,
        purchaseAmount: richText(renderer["purchaseAmountText"]),
        stickerURL: key == "liveChatPaidStickerRenderer" ? renderer["sticker"]?.firstThumbnailURL() : nil
      )
    }
    return nil
  }

  /// JSONValue.text intentionally ignores emoji runs; chat must preserve them alongside ordinary text.
  private static func richText(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    guard let runs = value["runs"]?.array else { return nonempty(value.text) }
    var text = ""
    for run in runs {
      if let plain = run["text"]?.string {
        text += plain
      } else if let emoji = run["emoji"] {
        let shortcut = emoji["shortcuts"]?.array?.lazy.compactMap { nonempty($0.string) }.first
        text += shortcut ?? accessibilityLabel(emoji["image"]) ?? accessibilityLabel(emoji)
          ?? nonempty(emoji["emojiId"]?.string) ?? ""
      }
    }
    return nonempty(text)
  }

  private static func accessibilityLabel(_ value: JSONValue?) -> String? {
    nonempty(value?["accessibility", "accessibilityData", "label"]?.string)
      ?? nonempty(value?["accessibilityData", "label"]?.string)
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
