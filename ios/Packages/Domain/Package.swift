// swift-tools-version: 6.0
import PackageDescription

// Paquet Domain : vide au lot 9.1, rempli par les sous-tickets suivants.
let package = Package(
  name: "Domain",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "Domain", targets: ["Domain"])],
  targets: [
    .target(name: "Domain"),
    .testTarget(name: "DomainTests", dependencies: ["Domain"]),
  ],
  swiftLanguageModes: [.v6]
)
