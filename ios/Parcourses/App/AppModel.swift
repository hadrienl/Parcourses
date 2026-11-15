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
  /// Compte de l'appareil (#87), reconstruit avec l'environnement.
  private(set) var account: AccountSession?
  /// Drapeau `account.deletion` trouvé au lancement : la reprise de la suppression remplace l'app jusqu'à son issue,
  /// sans synchronisation ni `ensureSession`.
  private(set) var isResumingDeletion: Bool
  let gateway: (any RemoteGateway)?
  /// Une opération de compte à la fois (vérification d'un code, rejeux, déconnexion), même d'une reconstruction à
  /// l'autre de l'app.
  private let accountOperations = AccountOperationQueue()

  init(
    flags: any AccountDeletionFlagStore = UserDefaultsAccountDeletionFlagStore(),
    signOutFlags: any AccountSignOutFlagStore = UserDefaultsAccountSignOutFlagStore()
  ) {
    let gateway = AuthBootstrap.makeGateway()
    self.gateway = gateway
    environment = Result { try AppEnvironment.live(gateway: gateway) }
    isResumingDeletion = flags.isDeletionPending
    let current = try? environment.get()
    deletion = current?.makeAccountDeletion()
    deletion?.host = self
    account = current?.makeAccountSession(operations: accountOperations)
    account?.host = self
    // Déconnexion interrompue par un arrêt de l'app : la purge est achevée avant toute synchro, qui reste arrêtée sinon.
    if signOutFlags.isPending, account?.resumePendingSignOut() == true { current?.sync?.resume() }
    // Avant tout `perform()` : l'app peut être lancée en arrière-plan par « Cocher le suivant », sans scène.
    // Jamais pendant une suppression : la coche irait dans des données sur le point d'être effacées.
    if !isResumingDeletion { CheckNextItemRouter.handler = current?.activityActions }
  }

  /// Au lancement, avant la synchro : changement de compte interrompu (drapeau `account.switch`), achevé puis synchro
  /// reprise. Sinon la synchro reste arrêtée, et `foreground()` réessaie.
  func resumePendingSwitch() async {
    guard let account, account.hasPendingSwitch else { return }
    if await account.resumePendingSwitch() { sync?.resume() }
  }

  /// Retour au premier plan : un changement de compte encore dû (rejeu en échec, ou purge restée en attente après un
  /// code vérifié) est rejoué, puis le compte relu.
  func foreground() async {
    if await account?.replayPendingSwitch() == true { sync?.resume() }
    await account?.refresh()
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
    (try? environment.get())?.resumeShoppingAfterDeletion()
  }

  func stopSync() async {
    await sync?.stop()
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
    account = next?.makeAccountSession(operations: accountOperations)
    account?.host = self
    CheckNextItemRouter.handler = next?.activityActions
    // Aucune visite ne survit à la purge : toute activité encore affichée est orpheline.
    next?.endOrphanActivities(keeping: nil)
    SyncRuntime.scheduleBackgroundRefresh()
  }
}
