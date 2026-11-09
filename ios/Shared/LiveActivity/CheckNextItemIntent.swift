import AppIntents
import Foundation
import os

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

  #if compiler(>=6.4)
    /// SDK iOS 27 : l'exécution dans l'app est demandée explicitement. Avant, et avec un SDK plus ancien (CI),
    /// c'est la règle de `LiveActivityIntent` qui la garantit.
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif

  private static let log = Logger(subsystem: "app.parcourses", category: "LiveActivity")

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let visit = UUID(uuidString: visitId), let item = UUID(uuidString: itemId) else {
      Self.log.error("« Cocher le suivant » : identifiants illisibles")
      return .result()
    }
    guard let handler = CheckNextItemRouter.handler else {
      // Exécuté hors de l'app, ou avant son initialisation : le bouton ne ferait rien en silence.
      Self.log.error("« Cocher le suivant » sans gestionnaire : intent exécuté hors de l'app ?")
      return .result()
    }
    await handler.checkNext(visitId: visit, itemId: item)
    return .result()
  }
}
