import SwiftData

/// Plan de migration : chaque nouvelle version s'ajoute à `schemas`, avec son étape dans `stages`.
nonisolated enum ParcoursesMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}
