import Foundation
import Testing
@testable import MioTubeCore

@Suite struct LiveChatParserTests {
  @Test func parsesTextEmojiPaidStickerAndMembershipRows() throws {
    let page = LiveChatParser.parse(chatResponse(items: [
      ["liveChatTextMessageRenderer": [
        "id": "text", "authorName": ["simpleText": "Alice"], "authorExternalChannelId": "UC-A",
        "authorPhoto": ["thumbnails": [["url": "//example.com/small", "width": 32], ["url": "//example.com/large", "width": 64]]],
        "timestampText": ["simpleText": "12:34 PM"],
        "message": ["runs": [
          ["text": "Hello "], ["emoji": ["shortcuts": [":wave:"], "image": ["accessibility": ["accessibilityData": ["label": "wave"]]]]],
          ["text": " "], ["emoji": ["image": ["accessibility": ["accessibilityData": ["label": "smiling face"]]]]],
          ["text": " "], ["emoji": ["emojiId": "❤️"]],
        ]],
        "authorBadges": [
          ["liveChatAuthorBadgeRenderer": ["accessibility": ["accessibilityData": ["label": "Moderator"]], "tooltip": "Mod"]],
          ["liveChatAuthorBadgeRenderer": ["tooltip": "Member (2 years)"]],
        ],
      ]],
      ["liveChatPaidMessageRenderer": [
        "id": "paid", "authorName": ["runs": [["text": "Bob"]]],
        "purchaseAmountText": ["simpleText": "$5.00"],
        "message": ["runs": [["text": "Thanks "], ["emoji": ["shortcuts": [":heart:"]]]]],
      ]],
      ["liveChatPaidStickerRenderer": [
        "id": "sticker", "authorName": ["simpleText": "Cara"], "purchaseAmountText": ["simpleText": "$2.00"],
        "sticker": [
          "thumbnails": [["url": "https://example.com/sticker", "width": 96]],
          "accessibility": ["accessibilityData": ["label": "Celebrating sticker"]],
        ],
      ]],
      ["liveChatMembershipItemRenderer": [
        "id": "member", "authorName": ["simpleText": "Dan"],
        "headerPrimaryText": ["runs": [["text": "Member for 6 months"]]],
        "headerSubtext": ["simpleText": "Gold"],
        "message": ["runs": [["text": "Happy to be here "], ["emoji": ["shortcuts": [":party:"]]]]],
      ]],
    ]))
    #expect(page.messages.map(\.id) == ["text", "paid", "sticker", "member"])
    let text = try #require(page.messages.first)
    #expect(text.author == "Alice")
    #expect(text.authorChannelID == "UC-A")
    #expect(text.avatarURL?.absoluteString == "https://example.com/large")
    #expect(text.timestampText == "12:34 PM")
    #expect(text.text == "Hello :wave: smiling face ❤️")
    #expect(text.badges == ["Moderator", "Member (2 years)"])
    #expect(page.messages[1].author == "Bob")
    #expect(page.messages[1].purchaseAmount == "$5.00")
    #expect(page.messages[1].text == "Thanks :heart:")
    #expect(page.messages[2].text == "Celebrating sticker")
    #expect(page.messages[2].purchaseAmount == "$2.00")
    #expect(page.messages[2].stickerURL?.absoluteString == "https://example.com/sticker")
    #expect(page.messages[0].stickerURL == nil)
    #expect(page.messages[3].text == "Member for 6 months\nGold\nHappy to be here :party:")
  }

  @Test func discoversOnlyChatOwnedLiveContinuation() {
    let next: JSONValue = [
      "comments": ["continuations": [["timedContinuationData": ["continuation": "comments"]]]],
      "contents": ["liveChatRenderer": [
        "header": ["continuations": [["reloadContinuationData": ["continuation": "menu"]]]],
        "continuations": [
          ["liveChatReplayContinuationData": ["continuation": "replay"]],
          ["invalidationContinuationData": ["continuation": ""]],
          ["reloadContinuationData": ["continuation": "live"]],
        ],
      ]],
    ]
    #expect(LiveChatParser.initialContinuation(in: next) == "live")
    #expect(LiveChatParser.initialContinuation(in: ["liveChatRenderer": [
      "isReplay": true, "continuations": [["reloadContinuationData": ["continuation": "replay"]]],
    ]]) == nil)
    #expect(LiveChatParser.initialContinuation(in: ["liveChatRenderer": [
      "continuations": [["liveChatReplayContinuationData": ["continuation": "replay"]]],
    ]]) == nil)
    #expect(LiveChatParser.initialContinuation(in: ["continuationCommand": ["token": "not-chat"]]) == nil)
  }

  @Test func supportsLiveContinuationKindsAndServerTiming() {
    for key in ["timedContinuationData", "invalidationContinuationData", "reloadContinuationData"] {
      let continuation: JSONValue = .object([key: ["continuation": "next", "timeoutMs": "250"]])
      let page = LiveChatParser.parse(chatResponse(continuations: [continuation]))
      #expect(page.continuation == "next")
      #expect(page.pollIntervalMilliseconds == 250)
      #expect(LiveChatParser.initialContinuation(in: ["liveChatRenderer": ["continuations": .array([continuation])]]) == "next")
    }
    for timeout in [JSONValue.null, .number(0), .number(-100), .string("not-a-number")] {
      let page = LiveChatParser.parse(chatResponse(continuations: [
        ["timedContinuationData": ["continuation": "next", "timeoutMs": timeout]],
      ]))
      #expect(page.continuation == "next")
      #expect(page.pollIntervalMilliseconds == 5_000)
    }
    let reload = LiveChatParser.parse(chatResponse(continuations: [["reloadContinuationData": ["continuation": "reload"]]]))
    #expect(reload.pollIntervalMilliseconds == 5_000)
    let longWait = LiveChatParser.parse(chatResponse(continuations: [
      ["invalidationContinuationData": ["continuation": "later", "timeoutMs": 120_000]],
    ]))
    #expect(longWait.pollIntervalMilliseconds == 120_000)
  }

  @Test func noLiveContinuationMeansEndedIncludingReplayOnlyResponses() {
    let page = LiveChatParser.parse(chatResponse(items: [chatItem("last")]))
    #expect(page.messages.map(\.id) == ["last"])
    #expect(page.continuation == nil)
    #expect(page.pollIntervalMilliseconds > 0)
    let replayOnly = LiveChatParser.parse(chatResponse(continuations: [
      ["liveChatReplayContinuationData": ["continuation": "replay", "timeoutMs": 0]],
      ["timedContinuationData": ["continuation": ""]],
    ]))
    #expect(replayOnly.continuation == nil)
    let replay = LiveChatParser.parse(["continuationContents": ["liveChatReplayContinuation": [
      "actions": .array([addChatItem("replay")]),
    ]]])
    #expect(replay.messages.isEmpty)
    #expect(replay.continuation == nil)
    #expect(LiveChatParser.parse(.null).continuation == nil)
  }

  @Test func ignoresTickerReplayUnsupportedAndUnidentifiedRows() {
    let page = LiveChatParser.parse(chatResponse(
      items: [["liveChatTextMessageRenderer": ["message": ["simpleText": "No identity"]]], ["liveChatViewerEngagementMessageRenderer": ["id": "notice"]]],
      actions: [
        ["replayChatItemAction": ["actions": .array([addChatItem("replay")])]],
        ["addLiveChatTickerItemAction": ["item": ["liveChatTickerPaidMessageItemRenderer": [
          "showItemEndpoint": ["showLiveChatItemEndpoint": ["renderer": chatItem("ticker")]],
        ]]]],
        addChatItem("live"),
      ]
    ))
    #expect(page.messages.map(\.id) == ["live"])
  }
}

@Suite struct LiveChatSessionTests {
  @Test func deduplicatesAcrossInitialItemsAndPagesWithoutMovingRows() {
    var session = LiveChatSession()
    let page = LiveChatParser.parse(chatResponse(items: [chatItem("a"), chatItem("b")], actions: [
      addChatItem("a", text: "duplicate"), addChatItem("c"),
    ]))
    session.apply(page)
    session.apply(page)
    #expect(session.messages.map(\.id) == ["a", "b", "c"])
    #expect(session.messages.first?.text == "a")
  }

  @Test func appliesReplacementRemovalAndReadditionInWireOrder() {
    var session = LiveChatSession()
    session.apply(LiveChatParser.parse(chatResponse(items: [chatItem("a"), chatItem("b"), chatItem("c")], actions: [
      ["replaceChatItemAction": ["targetItemId": "b", "replacementItem": chatItem("b", text: "edited")]],
      ["removeChatItemAction": ["targetItemId": "a"]],
      addChatItem("a", text: "back"),
      ["markChatItemAsDeletedAction": ["targetItemId": "c"]],
      addChatItem("c", text: "returned"),
      ["replaceChatItemAction": ["targetItemId": "missing", "replacementItem": chatItem("ignored")]],
    ])))
    #expect(session.messages.map(\.id) == ["b", "a", "c"])
    #expect(session.messages.map(\.text) == ["edited", "back", "returned"])
  }

  @Test func authorModerationRemovesOnlyMatchingRetainedMessages() {
    for action in ["removeChatItemByAuthorAction", "markChatItemsByAuthorAsDeletedAction"] {
      var session = LiveChatSession()
      session.apply(LiveChatParser.parse(chatResponse(items: [
        chatItem("a", author: "UC-A"), chatItem("b", author: "UC-B"), chatItem("c", author: "UC-A"),
        ["liveChatTextMessageRenderer": ["id": "unknown", "message": ["simpleText": "No channel"]]],
      ], actions: [
        .object([action: ["externalChannelId": "UC-A"]]),
        .object([action: ["externalChannelId": ""]]),
        addChatItem("a", author: "UC-A", text: "after moderation"),
      ])))
      #expect(session.messages.map(\.id) == ["b", "unknown", "a"])
      #expect(session.messages.last?.text == "after moderation")
    }
  }

  @Test func replacementIDsStayUniqueAndReplacementStaysAtTargetPosition() {
    var session = LiveChatSession()
    session.apply(LiveChatParser.parse(chatResponse(items: [chatItem("a"), chatItem("b"), chatItem("c")], actions: [
      ["replaceChatItemAction": ["targetItemId": "c", "replacementItem": chatItem("a", text: "replacement")]],
      addChatItem("c", text: "new c"),
      addChatItem("a", text: "duplicate"),
    ])))
    #expect(session.messages.map(\.id) == ["b", "a", "c"])
    #expect(session.messages.map(\.text) == ["b", "replacement", "new c"])
  }

  @Test func retainsNewest300AndAllowsEvictedIDsWithoutUnboundedHistory() {
    var session = LiveChatSession()
    session.apply(LiveChatParser.parse(chatResponse(actions: (0..<650).map { addChatItem(String($0)) })))
    #expect(session.messages.count == 300)
    #expect(session.messages.first?.id == "350")
    #expect(session.messages.last?.id == "649")
    session.apply(LiveChatParser.parse(chatResponse(actions: [
      addChatItem("649"), addChatItem("0"),
      ["replaceChatItemAction": ["targetItemId": "349", "replacementItem": chatItem("old")]],
    ])))
    #expect(session.messages.count == 300)
    #expect(session.messages.first?.id == "351")
    #expect(session.messages.last?.id == "0")
    #expect(!session.messages.contains { $0.id == "old" })
    session.reset()
    #expect(session.messages.isEmpty)
    session.apply(LiveChatParser.parse(chatResponse(items: [chatItem("0")])))
    #expect(session.messages.map(\.id) == ["0"])
  }
}

private func chatResponse(
  items: [JSONValue] = [], actions: [JSONValue] = [], continuations: [JSONValue] = []
) -> JSONValue {
  ["continuationContents": ["liveChatContinuation": [
    "items": .array(items), "actions": .array(actions), "continuations": .array(continuations),
  ]]]
}

private func chatItem(_ id: String, author: String = "UC-A", text: String? = nil) -> JSONValue {
  ["liveChatTextMessageRenderer": [
    "id": .string(id), "authorExternalChannelId": .string(author), "authorName": ["simpleText": "Author"],
    "message": ["simpleText": .string(text ?? id)],
  ]]
}

private func addChatItem(_ id: String, author: String = "UC-A", text: String? = nil) -> JSONValue {
  ["addChatItemAction": ["item": chatItem(id, author: author, text: text)]]
}
