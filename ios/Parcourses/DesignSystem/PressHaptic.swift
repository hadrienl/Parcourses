import CoreHaptics
import UIKit

/// Choc de l'appui long des lignes sans menu (#115), au plus près du « tic » franc du menu natif de « Mes listes »,
/// dont le générateur est privé. Essais sur iPhone : `.medium` trop faible, `.heavy` fort mais sourd, `.rigid` du
/// bon timbre mais trop faible. D'où un choc transitoire CoreHaptics à pleine intensité ; la netteté reste sous 1, qui
/// retirerait du corps au choc.
///
/// Le moteur démarre au toucher (`prepare()`), pour jouer sans latence au déclenchement (`play()`), et s'arrête quand
/// l'écran disparaît (`stop()`). Sans moteur (appareil sans retour haptique, moteur arrêté par le système, démarrage en
/// cours), repli sur un choc rigide à pleine intensité.
@MainActor
final class PressHaptic {
  static let intensity: Float = 1
  static let sharpness: Float = 0.75

  private enum EngineState { case idle, starting, running }

  private var engine: CHHapticEngine?
  /// Change à chaque moteur créé ou arrêté : un rappel d'un ancien moteur est ignoré.
  private var generation = 0
  private var state: EngineState = .idle
  private let fallback = UIImpactFeedbackGenerator(style: .rigid)

  /// Au toucher : démarre le moteur s'il ne tourne pas, et prépare le repli.
  func prepare() {
    fallback.prepare()
    guard state == .idle, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    if engine == nil { engine = makeEngine() }
    guard let engine else { return }
    state = .starting
    let current = generation
    let started = Self.onMain { [weak self] (failed: Bool) in
      guard let self, self.generation == current, self.state == .starting else { return }
      self.state = failed ? .idle : .running
    }
    engine.start { @Sendable error in started(error != nil) }
  }

  /// Au déclenchement de l'appui long.
  func play() {
    if state == .running, let engine {
      do {
        try engine.makePlayer(with: Self.pattern()).start(atTime: CHHapticTimeImmediate)
        return
      } catch {
        state = .idle
      }
    }
    fallback.impactOccurred(intensity: 1.0)
  }

  /// Quand l'écran disparaît.
  func stop() {
    engine?.stop(completionHandler: nil)
    engine = nil
    generation += 1
    state = .idle
  }

  private func makeEngine() -> CHHapticEngine? {
    guard let engine = try? CHHapticEngine() else { return nil }
    engine.playsHapticsOnly = true
    generation += 1
    let current = generation
    // Arrêt ou réinitialisation par le système (mise en arrière-plan, serveur haptique relancé) : le prochain toucher
    // redémarre le moteur.
    let idle = Self.onMain { [weak self] (_: Void) in
      guard let self, self.generation == current else { return }
      self.state = .idle
    }
    engine.stoppedHandler = { @Sendable _ in idle(()) }
    engine.resetHandler = { @Sendable in idle(()) }
    return engine
  }

  private static func pattern() throws -> CHHapticPattern {
    let event = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
      ],
      relativeTime: 0)
    return try CHHapticPattern(events: [event], parameters: [])
  }

  /// Les rappels du moteur arrivent sur une file quelconque : on revient sur le fil principal.
  private nonisolated static func onMain<T: Sendable>(
    _ body: @escaping @MainActor @Sendable (T) -> Void
  ) -> @Sendable (T) -> Void {
    { value in Task { @MainActor in body(value) } }
  }
}
