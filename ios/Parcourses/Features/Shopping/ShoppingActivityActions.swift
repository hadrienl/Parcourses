import Domain
import Foundation
import os

/// « Cocher le suivant » de la Live Activity (#10 §9), pendant de `ShoppingLiveUpdates.checkNext` d'Android.
///
/// Même règle que l'écran : seul un article que l'activité montre encore à prendre se coche, par
/// `VisitRepository.checkItem`, qui refuse un article déjà coché (double appui, ou écran au même instant) sans
/// erreur à l'écran. Même retenue d'envoi que l'écran (5 s), mais pas d'« Annuler ». Mode courses ouvert, il
/// l'apprend et retrie ; sinon (app relancée en arrière-plan) l'état affiché est confronté à la base, sans tri.
@MainActor
final class ShoppingActivityActions: CheckNextItemHandling {
  private static let log = Logger(subsystem: "app.parcourses", category: "LiveActivity")

  private let lists: any ListRepository
  private let visits: any VisitRepository
  private let stores: any StoreRepository
  private let categories: any CategoryRepository
  private let analyzer: EntryAnalyzer
  private let activity: any ShoppingActivityControlling
  private let session: () -> ShoppingSession?
  private let now: () -> Date
  private let scheduleSync: () -> Void

  /// `session` : le mode courses en mémoire, s'il y en a un. `scheduleSync` : planifie l'envoi de la coche, que
  /// l'app lancée en arrière-plan par l'intent ne fait pas d'elle-même (la synchro démarre avec la scène).
  init(
    lists: any ListRepository, visits: any VisitRepository, stores: any StoreRepository,
    categories: any CategoryRepository, analyzer: EntryAnalyzer, activity: any ShoppingActivityControlling,
    session: @escaping () -> ShoppingSession?, now: @escaping () -> Date = { .now },
    scheduleSync: @escaping () -> Void = { SyncRuntime.scheduleBackgroundRefresh() }
  ) {
    self.scheduleSync = scheduleSync
    self.lists = lists
    self.visits = visits
    self.stores = stores
    self.categories = categories
    self.analyzer = analyzer
    self.activity = activity
    self.session = session
    self.now = now
  }

  func checkNext(visitId: UUID, itemId: UUID) async {
    if await perform(visitId: visitId, itemId: itemId) { scheduleSync() }
    // L'app peut être suspendue dès le retour de l'intent : la mise à jour doit être partie.
    await activity.waitUntilIdle()
  }

  /// `true` si une coche a été écrite.
  private func perform(visitId: UUID, itemId: UUID) async -> Bool {
    guard let state = await activity.restore(visitId: visitId) else {
      Self.log.info("« Cocher le suivant » ignoré : l'activité ne suit plus cette visite")
      return false
    }
    // Un affichage dépassé (double appui) porte un article qui n'est plus à prendre : rien ne se passe.
    guard state.pendingItemIds.contains(itemId) else {
      Self.log.info("« Cocher le suivant » ignoré : article déjà pris")
      return false
    }
    // Visite close, sans liste ou périmée : l'activité n'a plus rien à suivre et part, comme la Live Update
    // Android (`lastActivityIfLive`), au lieu de garder un bouton sans effet.
    guard let visit = try? visits.visit(id: visitId), visit.endedAt == nil,
      (try? lists.list(id: visit.listId)) != nil
    else {
      Self.log.info("« Cocher le suivant » ignoré : visite close ou sans liste, activité retirée")
      activity.endAll(except: nil)
      return false
    }
    let last = (try? visits.lastActivity(visitId: visitId)) ?? visit.startedAt
    // Une visite périmée n'est pas reprise (elle sera close à sa dernière coche) : une coche ne la ranime pas.
    guard now().timeIntervalSince(last) < ShoppingSession.expiry else {
      Self.log.info("« Cocher le suivant » ignoré : visite périmée, activité retirée")
      activity.endAll(except: nil)
      return false
    }
    let items = (try? lists.items(listId: visit.listId)) ?? []
    // Supprimé ou introuvable entre-temps (synchro, écran) : rien n'est coché, l'affichage suit la base.
    guard let item = items.first(where: { $0.id == itemId }), item.notFoundAt == nil else {
      Self.log.info("« Cocher le suivant » ignoré : article plus à prendre")
      resync(state, visit: visit)
      return false
    }
    do {
      try visits.checkItem(
        visitId: visitId, itemId: itemId, subject: ShoppingSession.subject(of: item, analyzer: analyzer),
        checkedAt: now(), sendAfter: ShoppingSession.sendDelay())
    } catch RepositoryError.alreadyChecked(_) {
      // Coché à l'écran au même instant : l'affichage se met simplement à jour.
      Self.log.info("« Cocher le suivant » : article déjà coché")
      resync(state, visit: visit)
      return false
    } catch {
      Self.log.error("« Cocher le suivant » refusé : \(error.localizedDescription, privacy: .public)")
      return false
    }
    resync(state, visit: visit)
    return true
  }

  /// Mode courses ouvert sur cette visite : il relit et retrie. Sinon, ou s'il ne publie pas encore (préparation
  /// en cours, jusqu'à 3 s), l'état affiché est confronté à la base.
  private func resync(_ state: ShoppingActivityAttributes.ContentState, visit: Visit) {
    if let session = session(), session.visitId == visit.id, session.isActivityReady {
      session.checkedElsewhere()
    } else {
      refresh(state, visit: visit)
    }
  }

  /// Sans mode courses : l'état affiché, confronté à la base.
  private func refresh(_ state: ShoppingActivityAttributes.ContentState, visit: Visit) {
    let items = (try? lists.items(listId: visit.listId)) ?? []
    let storeOrganicAisle = (try? stores.store(id: visit.storeId))?.organicAisle ?? false
    let labels = Dictionary(
      ((try? categories.categories()) ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
    let refreshed = state.reconciled(items: items) { [analyzer] item in
      // Rayon effectif, comme celui des sections du mode courses (#28).
      let aisle = effectiveCategory(
        categoryId: item.categoryId, organic: analyzer.classify(label: item.label).organic,
        storeOrganicAisle: storeOrganicAisle)
      return (item.label, aisle, labels[aisle])
    }
    let last = (try? visits.lastActivity(visitId: visit.id)) ?? now()
    activity.update(state: refreshed, lastActivity: last)
  }
}
