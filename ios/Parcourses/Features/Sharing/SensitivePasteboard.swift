import Foundation
import UIKit
import UniformTypeIdentifiers

/// Lien d'invitation copié (#87 §3.5) : il porte le jeton, qui donne accès à la liste. Il reste sur cet appareil (pas
/// de presse-papiers universel vers le Mac ou l'iPad) et s'efface de lui-même au bout d'une heure, le temps de le
/// coller dans un message.
enum SensitivePasteboard {
  static let lifetime: TimeInterval = 3600

  /// Options du presse-papiers pour un texte copié à `now`.
  static func options(now: Date) -> [UIPasteboard.OptionsKey: Any] {
    [.localOnly: true, .expirationDate: now.addingTimeInterval(lifetime)]
  }

  static func copy(_ text: String, to pasteboard: UIPasteboard = .general, now: Date = .now) {
    pasteboard.setItems([[UTType.plainText.identifier: text]], options: options(now: now))
  }
}
