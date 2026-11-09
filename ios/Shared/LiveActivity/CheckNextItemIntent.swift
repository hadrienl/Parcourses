import AppIntents
import Foundation

/// Ce que fait l'app quand « Cocher le suivant » est touché sur la Live Activity. Seule l'app en fournit un :
/// l'extension affiche le bouton, l'intent s'exécute dans le processus de l'app (`LiveActivityIntent`), lancée en
/// arrière-plan si elle ne tourne pas.
@MainActor
protocol CheckNextItemHandling: AnyObject {
  /// Coche `itemId`, l'article que la Live Activity de `visitId` affichait, par la même règle que l'écran.
  func checkNext(visitId: UUID, itemId: UUID) async
}

/// Point d'accès de l'intent à l'app, renseigné au lancement (`ParcoursesApp.init`), avant tout `perform()`.
@MainActor
enum CheckNextItemRouter {
  static var handler: (any CheckNextItemHandling)?
}

/// Action « Cocher le suivant » de la Live Activity (#10 §9, pendant de l'action de la Live Update Android). Un
/// intent par article affiché : un toucher sur un affichage dépassé ne coche jamais un autre article.
struct CheckNextItemIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Cocher le suivant"
  static let description = IntentDescription("Coche le prochain article des courses en cours.")
  /// Sans intérêt hors de la Live Activity : ni Raccourcis ni Spotlight.
  static let isDiscoverable = false

  /// Identifiants en texte : `UUID` n'est pas un type de paramètre d'App Intents.
  @Parameter(title: "Visite")
  var visitId: String

  @Parameter(title: "Article")
  var itemId: String

  init() {}

  init(visitId: UUID, itemId: UUID) {
    self.visitId = visitId.uuidString
    self.itemId = itemId.uuidString
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    if let visit = UUID(uuidString: visitId), let item = UUID(uuidString: itemId) {
      await CheckNextItemRouter.handler?.checkNext(visitId: visit, itemId: item)
    }
    return .result()
  }
}
