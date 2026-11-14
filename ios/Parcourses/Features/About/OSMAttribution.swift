import SwiftUI

/// Licence ODbL des données OpenStreetMap, exigée avec l'attribution.
enum OpenStreetMap {
  static let copyright = URL(string: "https://www.openstreetmap.org/copyright")
  static let credit = "© contributeurs OpenStreetMap"
}

/// Attribution à afficher partout où des données de magasins sont montrées (#9 §8).
struct OSMAttribution: View {
  var body: some View {
    Group {
      if let url = OpenStreetMap.copyright {
        // La zone tactile est celle du lien lui-même : le libellé occupe toute la largeur, 44 pt de haut.
        Link(destination: url) {
          Text(OpenStreetMap.credit)
            .underline()
            .frame(maxWidth: .infinity)
            .touchTarget()
        }
        .accessibilityHint("Ouvre la page des droits d'OpenStreetMap")
      } else {
        Text(OpenStreetMap.credit)
      }
    }
    .font(.caption)
    .multilineTextAlignment(.center)
    .accessibilityIdentifier("osmAttribution")
  }
}
