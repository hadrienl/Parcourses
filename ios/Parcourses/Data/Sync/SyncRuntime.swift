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
  private var networkTask: Task<Void, Never>?

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
    foreground()
  }

  /// À appeler dès qu'une session valide est disponible.
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

/// Temps d'exécution demandé au système, rendu une seule fois.
private final class BackgroundActivity {
  private var identifier = UIBackgroundTaskIdentifier.invalid

  func begin(onExpiration: @escaping () -> Void) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: "sync") { [self] in
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
