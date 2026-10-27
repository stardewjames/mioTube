import Foundation

public enum SkipDecision: Equatable, Sendable {
  case none
  case skip(to: Double, segment: SponsorSegment)
  /// `mute(true, seg)` entering a mute segment; `mute(false, nil)` restores the user's volume.
  case mute(Bool, segment: SponsorSegment?)
}

/// Pure SponsorBlock decision logic, driven by the player's periodic time observer.
public struct SkipEngine: Sendable {
  public private(set) var fullVideoSponsored: Bool
  /// Segments with effective action `.skip`/`.mute` in enabled categories, sorted by start.
  public let segments: [SponsorSegment]
  public let tiltThreshold: Double

  private let actions: [String: SponsorAction]
  /// `prefixMaxEnd[i]` = max end over `segments[0...i]`; bounds the backward scan.
  private let prefixMaxEnd: [Double]
  private var mutedSegment: SponsorSegment?
  private var muteOverrideUUID: String?
  private var suppressed: Set<String> = []

  public init(
    segments: [SponsorSegment], enabled: Set<SponsorCategory>,
    categoryOverrides: [SponsorCategory: SponsorAction] = [:], tiltThreshold: Double = 0.05
  ) {
    var full = false
    var actionable: [SponsorSegment] = []
    var actions: [String: SponsorAction] = [:]
    for segment in segments where enabled.contains(segment.category) {
      if segment.action == .full {
        full = true
        continue
      }
      let effective = categoryOverrides[segment.category] ?? segment.action
      guard effective == .skip || effective == .mute, segment.end > segment.start else { continue }
      actionable.append(segment)
      actions[segment.uuid] = effective
    }
    actionable.sort { $0.start < $1.start }
    var running = -Double.infinity
    self.prefixMaxEnd = actionable.map { running = max(running, $0.end); return running }
    self.segments = actionable
    self.actions = actions
    self.fullVideoSponsored = full
    self.tiltThreshold = tiltThreshold
  }

  public func action(for segment: SponsorSegment) -> SponsorAction? { actions[segment.uuid] }

  public mutating func evaluate(position: Double, muted: Bool) -> SkipDecision {
    // Skips first: chain through back-to-back segments so one seek clears them all.
    if let first = active(at: position + tiltThreshold, limit: position, action: .skip) {
      var target = first.end
      var guardCount = 0
      while let next = active(at: target + tiltThreshold, limit: target, action: .skip), next.end > target, guardCount < 32 {
        target = next.end
        guardCount += 1
      }
      return .skip(to: target, segment: first)
    }

    let muteSegment = active(at: position, limit: position, action: .mute)
    if let override = muteOverrideUUID, muteSegment?.uuid != override {
      muteOverrideUUID = nil
    }
    if let segment = muteSegment {
      if mutedSegment?.uuid == segment.uuid || muteOverrideUUID == segment.uuid { return .none }
      if mutedSegment == nil && muted { return .none } // user already muted; don't take ownership
      mutedSegment = segment
      return .mute(true, segment: segment)
    }
    if mutedSegment != nil {
      mutedSegment = nil
      return .mute(false, segment: nil)
    }
    return .none
  }

  /// The user changed mute themselves: stop managing it until the segment changes.
  public mutating func userToggledMute() {
    if let segment = mutedSegment {
      muteOverrideUUID = segment.uuid
      mutedSegment = nil
    }
  }

  /// "Undo" on a skip toast: never auto-skip this segment again this session.
  public mutating func suppress(_ segment: SponsorSegment) {
    suppressed.insert(segment.uuid)
  }

  /// Latest-starting segment with `start <= probe` and `limit < end` whose action matches.
  private func active(at probe: Double, limit: Double, action: SponsorAction) -> SponsorSegment? {
    var low = 0
    var high = segments.count
    while low < high {
      let mid = (low + high) / 2
      if segments[mid].start <= probe { low = mid + 1 } else { high = mid }
    }
    var index = low - 1
    while index >= 0, prefixMaxEnd[index] > limit {
      let segment = segments[index]
      if segment.end > limit, actions[segment.uuid] == action, !suppressed.contains(segment.uuid) {
        return segment
      }
      index -= 1
    }
    return nil
  }
}
