import Foundation
import TipKit

/// Astuce unique de l'écran Liste (#110) : après le premier article ajouté, elle apprend l'appui long. Elle disparaît
/// pour toujours quand on la ferme ou dès qu'on a ouvert le panneau de l'article (`invalidate(.actionPerformed)`).
/// TipKit garde cet état d'un lancement à l'autre.
struct QuantityTip: Tip {
  /// Un article ajouté par la saisie de cet appareil.
  static let itemAdded = Tips.Event(id: "itemAdded")

  var id: String { "quantityTip" }

  var title: Text {
    Text("Maintiens un article pour changer sa quantité")
  }

  var image: Image? {
    Image(systemName: "hand.tap")
  }

  var rules: [Rule] {
    #Rule(Self.itemAdded) { $0.donations.count >= 1 }
  }
}

enum ParcoursesTips {
  /// Au lancement. Tests UI (Debug) : astuces masquées, pour des écrans stables d'un test à l'autre, sauf avec
  /// `PARCOURSES_TEST_TIPS=1`, qui repart d'un état neuf (aucune astuce vue, aucun article ajouté).
  static func configure(variables: [String: String] = ProcessInfo.processInfo.environment) {
    #if DEBUG
      if variables["PARCOURSES_TEST_TIPS"] == "1" {
        try? Tips.resetDatastore()
      } else if variables.keys.contains(where: { $0.hasPrefix("PARCOURSES_TEST_") }) {
        Tips.hideAllTipsForTesting()
      }
    #endif
    try? Tips.configure([.displayFrequency(.immediate)])
  }
}
