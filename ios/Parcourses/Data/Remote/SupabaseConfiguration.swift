import Foundation

/// Adresse et clé publique de l'environnement Supabase, issues des `xcconfig` non versionnés.
nonisolated struct SupabaseConfiguration: Sendable, Equatable {
  let url: URL
  let publishableKey: String

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

  /// `nil` si l'environnement n'est pas renseigné : l'app reste alors entièrement locale.
  init?(url rawURL: String?, publishableKey: String?) {
    guard
      let rawURL, let publishableKey, !publishableKey.isEmpty,
      let url = URL(string: rawURL), let host = url.host(),
      // `http` n'est admis que sur la machine elle-même, jamais vers un serveur distant.
      url.scheme == "https" || (url.scheme == "http" && Self.loopbackHosts.contains(host))
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
