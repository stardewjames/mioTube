import Foundation

public struct WatchProgress: Codable, Sendable, Hashable {
  public var position: Double
  public var duration: Double
  public var updatedAt: Date

  public init(position: Double, duration: Double, updatedAt: Date) {
    self.position = position
    self.duration = duration
    self.updatedAt = updatedAt
  }

  /// Played share of the video, clamped to 0...1.
  public var fraction: Double {
    guard duration > 0 else { return 0 }
    return min(max(position / duration, 0), 1)
  }

  /// Watched once 90% has played, or the final 30 s are reached after the halfway point.
  public var isFinished: Bool {
    guard duration > 0 else { return false }
    return fraction >= 0.9 || (fraction >= 0.5 && position >= duration - 30)
  }
}

/// Resume positions in `progress.json`, keyed by video id.
public actor WatchProgressStore {
  public static let retention: TimeInterval = 90 * 86_400

  private let fileURL: URL?
  private var entries: [String: WatchProgress]?
  private var dirty = false

  /// `fileURL == nil` keeps progress in memory (tests).
  public init(fileURL: URL?) {
    self.fileURL = fileURL
  }

  public static func defaultFileURL() -> URL {
    FeedCache.defaultDirectory().deletingLastPathComponent().appendingPathComponent("progress.json")
  }

  public func progress(for videoID: String) -> WatchProgress? {
    load()[videoID]
  }

  /// Every retained entry; used to seed the in-memory index that feeds render from.
  public func snapshot() -> [String: WatchProgress] {
    load()
  }

  /// Saved position when it is meaningfully inside the video (30 s from either end), else 0.
  public func resumePosition(for videoID: String) -> Double {
    guard let entry = load()[videoID] else { return 0 }
    return Self.resumePosition(entry)
  }

  public static func resumePosition(_ entry: WatchProgress) -> Double {
    guard !entry.isFinished else { return 0 }
    return entry.position > 30 && entry.position < entry.duration - 30 ? entry.position : 0
  }

  public func record(videoID: String, position: Double, duration: Double, at date: Date = Date()) {
    guard position.isFinite, duration.isFinite, duration > 0 else { return }
    var all = load()
    all[videoID] = WatchProgress(position: position, duration: duration, updatedAt: date)
    entries = all
    dirty = true
  }

  public func flush() {
    guard dirty, let fileURL, let entries else { return }
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
      dirty = false
    } catch {
      // Best-effort; next flush retries.
    }
  }

  public func removeAll() {
    entries = [:]
    dirty = true
    flush()
  }

  private func load(now: Date = Date()) -> [String: WatchProgress] {
    if let entries { return entries }
    var loaded: [String: WatchProgress] = [:]
    if let fileURL, let data = try? Data(contentsOf: fileURL),
       let decoded = try? JSONDecoder().decode([String: WatchProgress].self, from: data) {
      loaded = decoded.filter { now.timeIntervalSince($0.value.updatedAt) < Self.retention }
      dirty = loaded.count != decoded.count
    }
    entries = loaded
    return loaded
  }
}
