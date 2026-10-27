import Foundation

public enum RendererTree {
  /// Depth-first; calls `visit(key, value)` for every object member whose key ends in
  /// `Renderer` or `ViewModel`, then keeps descending into it.
  public static func walk(_ v: JSONValue, _ visit: (String, JSONValue) -> Void) {
    switch v {
    case .object(let object):
      for (key, value) in object {
        if key.hasSuffix("Renderer") || key.hasSuffix("ViewModel") { visit(key, value) }
        walk(value, visit)
      }
    case .array(let array):
      for value in array { walk(value, visit) }
    default:
      break
    }
  }

  /// First renderer named `name` anywhere under `v`.
  public static func first(_ name: String, in v: JSONValue) -> JSONValue? {
    v.first(key: name)
  }

  /// Continuation token in either the legacy or the 2026 continuation-item shape.
  public static func continuationToken(_ v: JSONValue) -> String? {
    if let token = v["continuationEndpoint", "continuationCommand", "token"]?.string { return token }
    if let token = v["continuationCommand", "innertubeCommand", "continuationCommand", "token"]?.string { return token }
    if let token = v["button", "buttonRenderer", "command", "continuationCommand", "token"]?.string { return token }
    return v.first(key: "continuationCommand")?["token"]?.string
  }
}
