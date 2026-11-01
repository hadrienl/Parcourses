// swift-tools-version: 6.0
import PackageDescription

// Paquet Domain : types purs, normalisation des libellés et classifieur par mots-clés (#7).
let package = Package(
  name: "Domain",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "Domain", targets: ["Domain"])],
  targets: [
    // Le dictionnaire est copié depuis shared/categories/ (ios/scripts/sync-categories.sh, vérifié en CI).
    // `.process` aplatit le bundle : codesign refuse un dossier `Resources/` à la racine d'un bundle iOS.
    .target(name: "Domain", resources: [.process("Resources")]),
    .testTarget(name: "DomainTests", dependencies: ["Domain"]),
  ],
  swiftLanguageModes: [.v6]
)
