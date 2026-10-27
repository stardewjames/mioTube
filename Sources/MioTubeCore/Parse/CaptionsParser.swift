import Foundation

public struct Cue: Sendable, Hashable {
  public let start: Double
  public let end: Double
  public let text: String

  public init(start: Double, end: Double, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }
}

public struct Captions: Sendable, Hashable {
  /// Sorted by `start`.
  public let cues: [Cue]

  public init(cues: [Cue]) {
    self.cues = cues.sorted { $0.start < $1.start }
  }

  /// Cue visible at `t` (latest-starting one when cues overlap). Binary search on start.
  public func cue(at t: Double) -> Cue? {
    var low = 0
    var high = cues.count
    while low < high {
      let mid = (low + high) / 2
      if cues[mid].start <= t { low = mid + 1 } else { high = mid }
    }
    var index = low - 1
    // Overlapping cues: walk back a few to find one still active.
    var steps = 0
    while index >= 0, steps < 8 {
      if cues[index].end > t { return cues[index] }
      index -= 1
      steps += 1
    }
    return nil
  }
}

public enum CaptionsParser {
  /// Fetches `track` as WebVTT. Nil when unavailable (403/empty/garbage): the UI hides captions;
  /// there is no retry.
  public static func fetch(_ track: CaptionTrack, transport: any HTTPTransport) async -> Captions? {
    var components = URLComponents(url: track.baseURL, resolvingAgainstBaseURL: false)
    var items = (components?.queryItems ?? []).filter { $0.name != "fmt" }
    items.append(URLQueryItem(name: "fmt", value: "vtt"))
    components?.queryItems = items
    guard let url = components?.url,
          let response = try? await transport.send(HTTPRequest(url: url, timeout: 15)),
          !response.data.isEmpty
    else { return nil }
    let captions = parse(String(decoding: response.data, as: UTF8.self))
    return captions.cues.isEmpty ? nil : captions
  }

  public static func parse(_ vtt: String) -> Captions {
    let normalized = vtt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    var cues: [RawCue] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      guard line.contains("-->"), let timing = parseTiming(line) else {
        index += 1
        continue
      }
      index += 1
      var textLines: [String] = []
      // A cue payload ends at an *empty* line; whitespace-only lines (" ") are payload, as in
      // YouTube's auto-generated tracks.
      while index < lines.count, !lines[index].isEmpty {
        textLines.append(clean(String(lines[index])))
        index += 1
      }
      let payload = textLines.filter { !$0.isEmpty }
      if !payload.isEmpty { cues.append(RawCue(start: timing.0, end: timing.1, lines: payload)) }
    }
    return Captions(cues: collapseRollingCues(cues))
  }

  struct RawCue {
    let start: Double
    let end: Double
    let lines: [String]
  }

  /// YouTube's auto-generated VTT "rolls": every cue repeats the previous cue's line above the
  /// new one, and 10 ms filler cues re-show the finished line. Rendered as-is the text appears
  /// twice. Drop the filler cues and the lines carried over from the previous cue.
  static func collapseRollingCues(_ raw: [RawCue]) -> [Cue] {
    var result: [Cue] = []
    var previous: [String] = []
    var previousEnd = -Double.infinity
    for cue in raw.sorted(by: { $0.start < $1.start }) {
      if cue.end - cue.start < 0.05 { continue }
      let adjacent = cue.start - previousEnd < 0.5
      let fresh = adjacent ? cue.lines.filter { !previous.contains($0) } : cue.lines
      previous = cue.lines
      previousEnd = cue.end
      guard !fresh.isEmpty else { continue }
      result.append(Cue(start: cue.start, end: cue.end, text: fresh.joined(separator: "\n")))
    }
    return result
  }

  /// `00:00:03.000 --> 00:00:06.000 align:start position:0%`
  static func parseTiming(_ line: Substring) -> (Double, Double)? {
    let halves = line.components(separatedBy: "-->")
    guard halves.count == 2,
          let start = parseTimestamp(halves[0].trimmingCharacters(in: .whitespaces)),
          let endToken = halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
          let end = parseTimestamp(String(endToken))
    else { return nil }
    return (start, end)
  }

  /// `hh:mm:ss.mmm` or `mm:ss.mmm`.
  static func parseTimestamp(_ text: String) -> Double? {
    let parts = text.split(separator: ":")
    guard (2...3).contains(parts.count) else { return nil }
    var total = 0.0
    for part in parts {
      guard let value = Double(part.replacingOccurrences(of: ",", with: ".")) else { return nil }
      total = total * 60 + value
    }
    return total
  }

  static func clean(_ line: String) -> String {
    var out = ""
    var inTag = false
    for character in line {
      if character == "<" { inTag = true; continue }
      if character == ">" && inTag { inTag = false; continue }
      if !inTag { out.append(character) }
    }
    return decodeEntities(out).trimmingCharacters(in: .whitespaces)
  }

  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = text
    for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      result = result.replacingOccurrences(of: entity, with: value)
    }
    return result
  }
}
