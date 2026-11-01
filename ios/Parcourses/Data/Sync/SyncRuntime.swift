import BackgroundTasks
import Foundation
import OSLog
import Observation
import SwiftData

/// Branche le moteur sur la vie de l'app : lancement, premier plan, réseau, arrière-plan (#9 §5.3).
@Observable
final class SyncRuntime {
  static let backgroundTaskIdentifier = "app.parcourses.sync"
  private static let logger = Logger(subsystem: "app.parcourses", category: "sync")

  private let engine: SyncEngine
  private let monitor: NetworkMonitor
  private var networkTask: Task<Void, Never>?
  private var pauseTask: Task<Void, Never>?
  /// État à afficher : l'écran de connexion observe cette propriété.
  private(set) var pause: SyncPause?

  init(gateway: any RemoteGateway, container: ModelContainer) throws {
    let monitor = NetworkMonitor()
    self.monitor = monitor
    engine = SyncEngine(
      gateway: gateway, container: container, cursors: UserDefaultsSyncCursors(),
      classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(isOnline: { monitor.isOnline }))
  }

  /// Lancement : la première passe suit le premier état connu du réseau.
  func start() {
    guard networkTask == nil else { return }
    let engine = engine
    let returns = monitor.returns()
    networkTask = Task {
      for await _ in returns { await engine.kick(pull: true) }
    }
    pauseTask = Task { [weak self, updates = engine.pauseUpdates] in
      for await pause in updates { self?.pause = pause }
    }
    foreground()
  }

  /// À appeler dès qu'une session valide est disponible, ou la reprise de compte décidée.
  func sessionDidChange() {
    let engine = engine
    Task { await engine.resume() }
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

  static func scheduleBackgroundRefresh() {
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
