import SwiftData

/// Plan de migration : chaque nouvelle version s'ajoute à `schemas`, avec son étape dans `stages`.
nonisolated enum ParcoursesMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self] }
  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
      .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
    ]
  }
}
