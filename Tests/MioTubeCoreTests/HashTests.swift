import Testing
@testable import MioTubeCore

@Suite struct HashTests {
  @Test func sha256OfABC() {
    #expect(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func sha256PrefixForSponsorBlockPrivacyMode() {
    #expect(sha256Hex("AbCdEf123456").prefix(4) == "94eb")
  }
}
