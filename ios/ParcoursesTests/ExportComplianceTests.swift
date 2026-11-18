import Foundation
import Testing

/// Conformité à l'export (#145) : l'app n'utilise que le HTTPS du système, exempté. L'Info.plist le déclare, sans quoi
/// App Store Connect pose la question à chaque build envoyé. Tests hébergés dans l'app : `Bundle.main` est l'app.
struct ExportComplianceTests {
  @Test func appDeclaresOnlyExemptEncryption() throws {
    let value = try #require(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool)
    #expect(value == false)
  }
}
