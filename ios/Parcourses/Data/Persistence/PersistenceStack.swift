import Foundation
import SwiftData

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

  static func makeContainer(storage: Storage) throws -> ModelContainer {
    let schema = Schema(versionedSchema: SchemaV1.self)
    // Pas de CloudKit : la synchronisation passe par Supabase.
    let configuration: ModelConfiguration
    switch storage {
    case .appGroup(let identifier):
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
