// swift-tools-version: 6.0
import PackageDescription

// Paquet SortEngine : algorithme de tri de #5, en Swift pur et sans dépendance (#9 §6.1).
let package = Package(
  name: "SortEngine",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "SortEngine", targets: ["SortEngine"])],
  targets: [
    .target(name: "SortEngine"),
    .testTarget(name: "SortEngineTests", dependencies: ["SortEngine"]),
  ],
  swiftLanguageModes: [.v6]
)
