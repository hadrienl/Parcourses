import SwiftUI
import UIKit

// Jetons de la direction B3 « Ticket filé » (#6), tirés de `design/tokens-ticket-v2.json`. Les noms sont ceux du
// fichier de jetons, communs à iOS et Android.

/// Couleurs : claires, sombres, et variantes Contraste augmenté là où le jeton ne tient pas 3:1 (traits) ou 7:1
/// (texte secondaire). Résolues par UIKit, donc aussi dans les feuilles et le plein écran.
enum Palette {
  /// Fond du ticket et des écrans.
  static let paper = dynamic(light: 0xFBF7F0, dark: 0x12141A)
  /// Bord du papier, filets, fond des champs.
  static let paperEdge = dynamic(light: 0xEAE2D3, dark: 0x232631, lightHigh: 0x8C8577, darkHigh: 0x6B7180)
  static let ink = dynamic(light: 0x1A1C22, dark: 0xECEEF4, lightHigh: 0x000000, darkHigh: 0xFFFFFF)
  /// Texte secondaire : 6,9:1 sur `paper` en clair, 8,4:1 en sombre.
  static let inkMuted = dynamic(light: 0x545866, dark: 0xA6ABBA, lightHigh: 0x363944, darkHigh: 0xCDD1DC)
  /// 8:1 sur `paper` en clair.
  static let accent = dynamic(light: 0x2340C8, dark: 0x8FA6FF, lightHigh: 0x1A2F9C, darkHigh: 0xB3C2FF)
  static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B1550)
  /// Fil parcouru.
  static let thread = accent
  /// Fil à parcourir, anneaux des perles à venir : décoratif (la case porte l'état), assombri en contraste
  /// augmenté pour tenir 3:1.
  static let threadIdle = dynamic(light: 0xD5CEC0, dark: 0x353A48, lightHigh: 0x8C8577, darkHigh: 0x6B7180)
  /// Libellé d'un article coché, qui est aussi barré.
  static let checked = inkMuted

  /// Familles de couleur des rayons. La couleur ne touche que le trait de l'icône et l'anneau du nœud : le libellé
  /// du rayon est toujours affiché.
  enum Aisle {
    static let fresh = dynamic(light: 0x1F7A44, dark: 0x6FD39A)
    static let dairy = dynamic(light: 0x2A6FB0, dark: 0x86BEF2)
    static let grocery = dynamic(light: 0xA3520A, dark: 0xF2B06A)
    static let hygiene = dynamic(light: 0x8A3FA0, dark: 0xE0A3F0)
    static let bio = dynamic(light: 0x4F6F12, dark: 0xC3DC6A)
  }

  // Hors acteur : UIKit peut résoudre une couleur dynamique hors du fil principal.
  nonisolated private static func dynamic(
    light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil
  )
    -> Color
  {
    Color(
      uiColor: UIColor { traits in
        let isDark = traits.userInterfaceStyle == .dark
        let isHigh = traits.accessibilityContrast == .high
        let hex = isDark ? (isHigh ? darkHigh ?? dark : dark) : (isHigh ? lightHigh ?? light : light)
        return UIColor(
          red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      })
  }
}

/// Espacements.
enum Space {
  static let xs: CGFloat = 8
  static let s: CGFloat = 12
  static let m: CGFloat = 16
  static let l: CGFloat = 24
  static let xl: CGFloat = 32
}

/// Tailles fixes du ticket. Le fil et ses perles sont décoratifs : ils gardent leur taille, le texte grandit seul.
enum TicketMetrics {
  /// Gouttière du fil, à gauche des lignes.
  static let threadGutter: CGFloat = 28
  static let threadWidth: CGFloat = 3
  /// Contraste augmenté : fil plus épais (#9 §11).
  static let threadWidthIncreased: CGFloat = 5
  static let bead: CGFloat = 14
  static let beadNext: CGFloat = 18
  static let beadRing: CGFloat = 3
  /// Nœud de rayon sur le fil : anneau de 1,5 pt et icône de 20 pt.
  static let aisleNode: CGFloat = 28
  static let aisleNodeRing: CGFloat = 1.5
  static let aisleIcon: CGFloat = 20
  /// Case à cocher, mise à l'échelle avec le texte.
  static let checkBox: CGFloat = 28
  static let checkBoxRadius: CGFloat = 4
  static let rowMin: CGFloat = 56
  static let primaryAction: CGFloat = 56
  static let radius: CGFloat = 8
}

/// Typographie : chasse fixe système (SF Mono), sur les styles de texte pour suivre Dynamic Type jusqu'à AX5.
enum TicketFont {
  /// Titre du ticket (magasin ou liste), en capitales : 28 pt à la taille par défaut (jeton : 26).
  static let title = Font.system(.title, design: .monospaced).weight(.heavy)
  /// Espacement du titre : +0,04 em.
  static let titleTracking: CGFloat = 1
  /// Espacement du compteur : −0,03 em.
  static let totalTracking: CGFloat = -1.5
  static let meta = Font.system(.footnote, design: .monospaced)
  /// Libellé d'un rayon, en capitales espacées.
  static let aisle = Font.system(.caption, design: .monospaced).weight(.bold)
  static let aisleTracking: CGFloat = 1.4
  static let item = Font.system(.body, design: .monospaced).weight(.medium)
  /// Article suivant sur le trajet.
  static let itemNext = Font.system(.title3, design: .monospaced).weight(.bold)
  static let quantity = Font.system(.subheadline, design: .monospaced)
  /// Légende du compteur (« RESTE »).
  static let totalCaption = Font.system(.caption, design: .monospaced).weight(.semibold)

  /// Compteur « 05 » : 52 pt à la taille par défaut, mis à l'échelle comme le grand titre.
  static func total(size: CGFloat) -> Font {
    .system(size: size, weight: .heavy, design: .monospaced)
  }
}

/// Mouvement (#6) : ressorts du ticket, et fondu de 150 ms sans déplacement quand les animations sont réduites.
enum Motion {
  /// Coche : la case et la perle se remplissent.
  static func check(reduced: Bool) -> Animation {
    reduced ? fade : .spring(response: 0.25, dampingFraction: 0.8)
  }

  /// Réordonnancement des lignes et des rayons. Mouvement réduit : aucun déplacement, les lignes changent de place
  /// d'un coup (une liste ne sait pas fondre son ordre sans perdre le défilement et le focus VoiceOver).
  static func reorder(reduced: Bool) -> Animation? {
    reduced ? nil : .spring(response: 0.4, dampingFraction: 1)
  }

  /// Apparitions et disparitions (bannière, étiquette « ↑ appris »).
  static let fade = Animation.easeInOut(duration: 0.15)
  /// Durée d'affichage de l'étiquette « ↑ appris ».
  static let learnedTag: Duration = .seconds(3)
}
