// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MioTubeCore",
  platforms: [.iOS("26.0"), .macOS(.v15)],
  products: [.library(name: "MioTubeCore", targets: ["MioTubeCore"])],
  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
  targets: [
    .target(
      name: "MioTubeCore",
      dependencies: [.product(name: "Crypto", package: "swift-crypto")],
      resources: [.copy("Resources/ClientProfiles.json")]
    ),
    .testTarget(name: "MioTubeCoreTests", dependencies: ["MioTubeCore"], resources: [.copy("Fixtures")]),
  ]
)
