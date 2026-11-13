import Foundation
import Observation

/// État racine de l'app : l'environnement courant, et sa reconstruction après une suppression de compte (#68).
@Observable
final class AppModel {
  /// Une erreur ici (store illisible, App Group absent) s'affiche : on ne repart jamais sur un store vide en silence.
  private(set) var environment: Result<AppEnvironment, any Error>
  /// Change à chaque reconstruction : `RootView` repart de zéro, modèles d'écran compris.
  private(set) var generation = 0
  private(set) var deletion: AccountDeletion?
  /// Drapeau `account.deletion` trouvé au lancement : la reprise de la suppression remplace l'app jusqu'à son issue,
  /// sans synchronisation ni `ensureSession`.
  private(set) var isResumingDeletion: Bool
  let gateway: (any RemoteGateway)?

  init(flags: any AccountDeletionFlagStore = UserDefaultsAccountDeletionFlagStore()) {
    let gateway = AuthBootstrap.makeGateway()
    self.gateway = gateway
    environment = Result { try AppEnvironment.live(gateway: gateway) }
    isResumingDeletion = flags.isDeletionPending
    let current = try? environment.get()
    deletion = current?.makeAccountDeletion()
    deletion?.host = self
    // Avant tout `perform()` : l'app peut être lancée en arrière-plan par « Cocher le suivant », sans scène.
    // Jamais pendant une suppression : la coche irait dans des données sur le point d'être effacées.
    if !isResumingDeletion { CheckNextItemRouter.handler = current?.activityActions }
  }

  var sync: SyncRuntime? {
    try? environment.get().sync
  }

  /// Reprise terminée sans suppression (annulée ou refusée) : l'app démarre normalement.
  func endDeletionResume() {
    guard isResumingDeletion else { return }
    isResumingDeletion = false
    CheckNextItemRouter.handler = try? environment.get().activityActions
  }
}

extension AppModel: AccountDeletionHost {
  func suspendSync() async {
    await sync?.suspend()
  }

  func resumeSync() {
    sync?.resume()
    CheckNextItemRouter.handler = try? environment.get().activityActions
  }

  func endShopping() {
    (try? environment.get())?.endShoppingForDeletion()
  }

  func restart() {
    guard let current = try? environment.get() else { return }
    environment = Result { try current.restarted() }
    generation += 1
    isResumingDeletion = false
    let next = try? environment.get()
    deletion = next?.makeAccountDeletion()
    deletion?.host = self
    CheckNextItemRouter.handler = next?.activityActions
    SyncRuntime.scheduleBackgroundRefresh()
  }
}
