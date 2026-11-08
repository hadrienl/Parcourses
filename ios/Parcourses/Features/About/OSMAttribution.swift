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
            .contentShape(Rectangle())
        }
        .accessibilityHint("Ouvre la licence ODbL dans Safari")
      } else {
        Text(OpenStreetMap.credit)
      }
    }
    .font(.caption)
    .multilineTextAlignment(.center)
    .accessibilityIdentifier("osmAttribution")
  }
}

/// À propos : attribution des données, confidentialité, version.
struct AboutView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Les magasins et leurs adresses viennent d'OpenStreetMap, sous licence ODbL.")
          if let url = OpenStreetMap.copyright {
            Link("© OpenStreetMap contributors (ODbL)", destination: url)
              .touchTarget()
              .accessibilityIdentifier("aboutOSMLink")
          }
        } header: {
          Text("Données cartographiques")
        }
        Section {
          Text("Parcourses ne vous suit pas et n'utilise aucun outil d'analyse tiers.")
          Text(
            "Votre position sert une seule fois à trouver le magasin où vous êtes. Elle n'est ni conservée ni envoyée ailleurs que pour cette recherche."
          )
          Text("Vos listes et vos coches sont rattachées à un identifiant anonyme, sans nom ni e-mail.")
        } header: {
          Text("Confidentialité")
        }
        Section {
          LabeledContent("Version", value: Self.version)
        }
      }
      .navigationTitle("À propos")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("OK") { dismiss() }
            .accessibilityIdentifier("closeAbout")
        }
      }
    }
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "\(short) (\(build))"
  }
}
