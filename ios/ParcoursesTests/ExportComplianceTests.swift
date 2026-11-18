import Foundation
import Testing

/// Conformité à l'export (#145) : l'app n'utilise que le HTTPS du système, exempté. L'Info.plist le déclare, sans quoi
/// App Store Connect pose la question à chaque build envoyé. Tests hébergés dans l'app : `Bundle.main` est l'app.
struct ExportComplianceTests {
  @Test func appDeclaresOnlyExemptEncryption() throws {
    let value = try #require(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool)
    #expect(value == false)
  }

  /// Versions tirées des réglages (#145) : App Store Connect refuse une extension dont la version ou le numéro de
  /// build diffère de l'app. `fastlane beta` vérifie en plus les valeurs attendues dans l'archive.
  @Test func widgetsExtensionCarriesTheAppVersion() throws {
    let url = try #require(Bundle.main.builtInPlugInsURL?.appending(path: "ParcoursesWidgets.appex"))
    let widgets = try #require(Bundle(url: url))
    for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
      let app = try #require(Bundle.main.object(forInfoDictionaryKey: key) as? String)
      #expect(!app.isEmpty && !app.contains("$("), "\(key) non résolu : \(app)")
      #expect(widgets.object(forInfoDictionaryKey: key) as? String == app, "\(key) diffère dans l'extension")
    }
  }
}
