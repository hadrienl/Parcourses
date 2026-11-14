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

/// À propos : attribution des données, confidentialité, version.
struct AboutView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Les magasins et leurs adresses viennent d'OpenStreetMap, sous licence ODbL.")
          if let url = OpenStreetMap.copyright {
            Link(destination: url) {
              Text("\(OpenStreetMap.credit) (ODbL)").touchTarget()
            }
            .accessibilityHint("Ouvre la page des droits d'OpenStreetMap")
            .accessibilityIdentifier("aboutOSMLink")
          }
        } header: {
          Text("Données cartographiques")
        }
        Section {
          Text("Parcourses ne vous suit pas et n'utilise aucun outil d'analyse tiers.")
          Text(
            "Pour apprendre l'ordre des rayons, Parcourses enregistre vos listes, les magasins où vous faites vos courses, l'heure de vos visites et les articles que vous cochez. Ces données sont rattachées à un identifiant anonyme, sans nom ni e-mail."
          )
          Text(
            "Les noms d'articles que vous saisissez restent privés. Un nom ne rejoint le catalogue commun, sans lien avec vous, qu'une fois saisi par au moins trois personnes."
          )
          Text(
            "Seule votre position GPS n'est pas conservée : elle sert une seule fois à trouver le magasin où vous êtes, puis elle est oubliée."
          )
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
