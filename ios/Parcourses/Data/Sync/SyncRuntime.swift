import BackgroundTasks
import Foundation
import OSLog
import Observation
import SwiftData
import UIKit

/// Branche le moteur sur la vie de l'app : lancement, premier plan, réseau, arrière-plan (#9 §5.3).
@Observable
final class SyncRuntime {
  static let backgroundTaskIdentifier = "app.parcourses.sync"
  private static let logger = Logger(subsystem: "app.parcourses", category: "sync")

  private let engine: SyncEngine
  private let monitor: NetworkMonitor
  private let deletionFlags: any AccountDeletionFlagStore
  private var networkTask: Task<Void, Never>?
  /// Remplacé par un moteur neuf (suppression du compte) : plus rien ne doit le relancer.
  private var isStopped = false

  /// Le moteur naît suspendu si une suppression de compte est en cours (#68 §5.3) : il ne repart qu'avec `resume()`.
  init(
    gateway: any RemoteGateway, container: ModelContainer,
    deletionFlags: any AccountDeletionFlagStore = UserDefaultsAccountDeletionFlagStore()
  ) throws {
    let monitor = NetworkMonitor()
    self.monitor = monitor
    self.deletionFlags = deletionFlags
    engine = SyncEngine(
      gateway: gateway, container: container, cursors: UserDefaultsSyncCursors(),
      classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(isOnline: { monitor.isOnline }),
      suspended: deletionFlags.isDeletionPending)
  }

  /// Dernier état connu du réseau, optimiste avant le premier.
  var isOnline: Bool { monitor.isOnline }

  /// Lancement : la première passe suit le premier état connu du réseau.
  func start() {
    guard networkTask == nil, !isStopped else { return }
    let engine = engine
    let returns = monitor.returns()
    networkTask = Task {
      for await _ in returns { await engine.kick(pull: true) }
    }
    foreground()
  }

  /// À appeler dès qu'une session valide est disponible. Sans effet pendant une suppression de compte : la
  /// connexion lancée avant elle ne doit pas relancer le moteur.
  func sessionDidChange() {
    guard !isStopped, !deletionFlags.isDeletionPending else { return }
    let engine = engine
    Task { await engine.resume() }
  }

  /// Suppression du compte : plus aucune passe, celle en cours comprise, ni tâche d'arrière-plan planifiée.
  func suspend() async {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    await engine.suspend()
  }

  /// Suppression abandonnée ou refusée : la synchronisation reprend où elle en était.
  func resume() {
    guard !isStopped else { return }
    let engine = engine
    Task { await engine.resume() }
    Self.scheduleBackgroundRefresh()
  }

  /// Avant la purge du compte supprimé : arrêt définitif. Le moteur ne repart plus, même sur un
  /// `sessionDidChange` tardif, et n'écoute plus le réseau.
  func stop() async {
    isStopped = true
    networkTask?.cancel()
    networkTask = nil
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    await engine.stop()
  }

  func foreground() {
    let engine = engine
    Task { await engine.kick(pull: true) }
  }

  /// À passer aux repositories : une nouvelle entrée déclenche un envoi.
  var enqueued: () -> Void {
    let engine = engine
    return { Task { await engine.kick() } }
  }

  /// Corps de la tâche d'arrière-plan. L'annulation par le système interrompt la passe, la file reste intacte.
  func backgroundRefresh() async {
    await engine.drain(pull: true)
  }

  /// Passage en arrière-plan : le temps accordé par le système sert à vider la file.
  func enteredBackground() {
    let engine = engine
    let work = Task { await engine.drain() }
    let activity = BackgroundActivity()
    activity.begin { work.cancel() }
    Task {
      await work.value
      activity.end()
    }
  }

  /// Jamais pendant une suppression de compte : la tâche réveillerait un moteur qui doit rester arrêté.
  static func scheduleBackgroundRefresh(
    deletionFlags: any AccountDeletionFlagStore = UserDefaultsAccountDeletionFlagStore()
  ) {
    guard !deletionFlags.isDeletionPending else { return }
    let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Simulateur, ou actualisation désactivée : la file partira au prochain lancement.
      logger.notice("Actualisation en arrière-plan non planifiée : \(String(describing: error), privacy: .private)")
    }
  }
}

/// Temps d'exécution demandé au système, rendu une seule fois.
final class BackgroundActivity {
  private let name: String
  private var identifier = UIBackgroundTaskIdentifier.invalid

  init(name: String = "sync") {
    self.name = name
  }

  func begin(onExpiration: @escaping () -> Void) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
      onExpiration()
      end()
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
