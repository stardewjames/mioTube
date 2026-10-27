import Foundation
import MioTubeCore
import Security

/// `GoogleSession` JSON in one generic-password Keychain item.
actor KeychainSessionStore: SessionStore {
  nonisolated private static let service = "dev.miotube.session"
  nonisolated private static let account = "google"

  private var cached: GoogleSession?
  private var loaded = false

  func current() async -> GoogleSession? {
    if !loaded {
      cached = Self.read()
      loaded = true
    }
    return cached
  }

  func save(_ s: GoogleSession?) async {
    cached = s
    loaded = true
    guard let s, let data = try? JSONEncoder().encode(s) else {
      Self.delete()
      return
    }
    Self.write(data)
  }

  func clear() async {
    await save(nil)
  }

  nonisolated private static var baseQuery: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
  }

  nonisolated private static func read() -> GoogleSession? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return try? JSONDecoder().decode(GoogleSession.self, from: data)
  }

  nonisolated private static func write(_ data: Data) {
    let attributes: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insert = baseQuery
      for (key, value) in attributes { insert[key] = value }
      SecItemAdd(insert as CFDictionary, nil)
    }
  }

  nonisolated private static func delete() {
    SecItemDelete(baseQuery as CFDictionary)
  }
}
