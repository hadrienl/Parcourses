// swift-tools-version: 6.0
import PackageDescription

// Paquet SortEngine : vide au lot 9.1, rempli par les sous-tickets suivants.
let package = Package(
  name: "SortEngine",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "SortEngine", targets: ["SortEngine"])],
  dependencies: [.package(path: "../Domain")],
  targets: [
    .target(name: "SortEngine", dependencies: ["Domain"]),
    .testTarget(name: "SortEngineTests", dependencies: ["SortEngine"]),
  ],
  swiftLanguageModes: [.v6]
)
