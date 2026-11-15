import SwiftData

/// Plan de migration : chaque nouvelle version s'ajoute à `schemas`, avec son étape dans `stages`.
nonisolated enum ParcoursesMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self] }
  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
      .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
      // Colonnes ajoutées sans perte, puis les articles déjà accusés sont marqués comme présents sur le serveur.
      .custom(
        fromVersion: SchemaV3.self, toVersion: SchemaV4.self, willMigrate: nil,
        didMigrate: { context in try SchemaV4.markItemsOnServer(in: context) }),
      // Rôle (`owner` par défaut) et participants (vides) ajoutés : relus à la descente suivante.
      .lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self),
    ]
  }
}
