import Foundation

/// Adresse et clé publique de l'environnement Supabase, issues des `xcconfig` non versionnés.
nonisolated struct SupabaseConfiguration: Sendable, Equatable {
  let url: URL
  let publishableKey: String

  /// `nil` si l'environnement n'est pas renseigné : l'app reste alors entièrement locale.
  init?(url rawURL: String?, publishableKey: String?) {
    guard
      let rawURL, let publishableKey, !publishableKey.isEmpty,
      let url = URL(string: rawURL), url.host() != nil,
      url.scheme == "https" || url.scheme == "http"
    else { return nil }
    self.url = url
    self.publishableKey = publishableKey
  }

  init?(bundle: Bundle) {
    self.init(
      url: bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
      publishableKey: bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String
    )
  }
}
