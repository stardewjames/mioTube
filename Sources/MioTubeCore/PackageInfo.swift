import Foundation
import Crypto

/// Hex encoding used by every hash in the package.
public func sha256Hex(_ string: String) -> String {
  SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

public func sha1Hex(_ string: String) -> String {
  Insecure.SHA1.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}
