import Foundation
import SwiftData

/// Erreurs de construction du store.
nonisolated enum PersistenceError: Error, Equatable {
  /// App Group absent des entitlements : sans ce contrôle, SwiftData planterait.
  case appGroupUnavailable(String)
}

extension PersistenceError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable(let identifier): "L'App Group « \(identifier) » n'est pas disponible."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .appGroupUnavailable:
      "L'app n'est pas signée avec cette capacité. Dans Xcode, vérifiez l'onglet Signing & Capabilities (équipe et "
        + "App Groups), ou APP_GROUP_ID dans Config/Local.xcconfig, puis réinstallez l'app."
    }
  }
}

/// Construction du `ModelContainer` de l'app.
nonisolated enum PersistenceStack {
  /// Emplacement du store.
  enum Storage {
    /// Conteneur de l'App Group, partagé avec les extensions (#9 §10).
    case appGroup(String)
    /// Fichier explicite (tests de réouverture).
    case file(URL)
    /// En mémoire (tests, previews).
    case inMemory
  }

  static func makeContainer(
    storage: Storage,
    groupContainerURL: (String) -> URL? = {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }
  ) throws -> ModelContainer {
    let schema = Schema(versionedSchema: SchemaV3.self)
    // Pas de CloudKit : la synchronisation passe par Supabase.
    let configuration: ModelConfiguration
    switch storage {
    case .appGroup(let identifier):
      guard groupContainerURL(identifier) != nil else { throw PersistenceError.appGroupUnavailable(identifier) }
      configuration = ModelConfiguration(
        schema: schema, groupContainer: .identifier(identifier), cloudKitDatabase: .none)
    case .file(let url):
      configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    case .inMemory:
      configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    }
    return try ModelContainer(
      for: schema, migrationPlan: ParcoursesMigrationPlan.self, configurations: configuration)
  }
}
