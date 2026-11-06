/// A live-only, bounded chat window. Deduplication and moderation track only retained messages;
/// removed or evicted IDs may be added again by later actions without accumulating tombstones.
public struct LiveChatSession: Sendable {
  public private(set) var messages: [LiveChatMessage] = []
  private var messageIDs: Set<String> = []
  private static let messageLimit = 300

  public init() {}

  public mutating func reset() {
    messages.removeAll()
    messageIDs.removeAll()
  }

  public mutating func apply(_ page: LiveChatPage) {
    for mutation in page.mutations {
      switch mutation {
      case .add(let index):
        let message = page.messages[index]
        guard messageIDs.insert(message.id).inserted else { continue }
        if messages.count == Self.messageLimit {
          messageIDs.remove(messages.removeFirst().id)
        }
        messages.append(message)
      case .replace(let targetID, let index):
        guard var targetIndex = messages.firstIndex(where: { $0.id == targetID }) else { continue }
        let replacement = page.messages[index]
        if replacement.id != targetID,
           let duplicateIndex = messages.firstIndex(where: { $0.id == replacement.id }) {
          messages.remove(at: duplicateIndex)
          if duplicateIndex < targetIndex { targetIndex -= 1 }
        }
        messageIDs.remove(targetID)
        messages[targetIndex] = replacement
        messageIDs.insert(replacement.id)
      case .remove(let id):
        guard messageIDs.remove(id) != nil else { continue }
        messages.removeAll { $0.id == id }
      case .removeAuthor(let authorID):
        for index in messages.indices.reversed() where messages[index].authorChannelID == authorID {
          messageIDs.remove(messages.remove(at: index).id)
        }
      }
    }
  }
}
