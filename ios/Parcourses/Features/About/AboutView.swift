import SwiftUI

/// À propos : attribution des données, confidentialité, suppression des données, version.
struct AboutView: View {
  @Environment(\.dismiss) private var dismiss
  /// Absent dans les aperçus et les tests sans app : la section « Vos données » est alors masquée.
  @Environment(AccountDeletion.self) private var deletion: AccountDeletion?
  @State private var confirmsDeletion = false
  /// Lu à l'ouverture de la confirmation : une visite ouverte ajoute une phrase.
  @State private var interruptsShopping = false

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
            "Seule votre position GPS n'est pas conservée : elle sert une seule fois à trouver le magasin où vous êtes, puis elle est oubliée."
          )
          if deletion?.deletesServerData == true {
            Text(
              "Vous pouvez supprimer ces données à tout moment ci-dessous. Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
            )
          }
        } header: {
          Text("Confidentialité")
        }
        if let deletion {
          yourData(deletion)
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
            .disabled(isBlocking)
            .accessibilityIdentifier("closeAbout")
        }
      }
      .alert("Supprimer toutes vos données ?", isPresented: $confirmsDeletion) {
        Button("Supprimer", role: .destructive) {
          guard let deletion else { return }
          Task { await deletion.delete() }
        }
        .accessibilityIdentifier("confirmDeletion")
        Button("Annuler", role: .cancel) {}
          .accessibilityIdentifier("cancelDeletion")
      } message: {
        Text(confirmationMessage)
      }
    }
    .accountDeletionPresentation(deletion)
    // Une fois la requête partie, et tant qu'un doute attend « Réessayer » ou « Annuler », la feuille reste ouverte.
    .interactiveDismissDisabled(isBlocking)
  }

  private func yourData(_ deletion: AccountDeletion) -> some View {
    Section {
      Text(
        deletion.deletesServerData
          ? "Vous pouvez effacer vos listes, vos visites et votre identifiant anonyme, sur cet appareil et sur nos serveurs."
          : "Vous pouvez effacer vos listes et vos visites de cet appareil."
      )
      Button(role: .destructive) {
        interruptsShopping = deletion.interruptsShopping
        confirmsDeletion = true
      } label: {
        Text("Supprimer mes données…")
          .frame(maxWidth: .infinity, alignment: .leading)
          .touchTarget()
      }
      .disabled(isBlocking)
      .accessibilityHint("Demande une confirmation avant d'effacer")
      .accessibilityIdentifier("deleteMyData")
    } header: {
      Text("Vos données")
    }
  }

  /// Suppression en cours, ou doute sans réponse : rien ne ferme l'écran sans un choix explicite.
  private var isBlocking: Bool {
    deletion?.status == .deleting || deletion?.status == .failed(.unknown)
  }

  /// Textes de #68 §5.2 et §5.7.
  private var confirmationMessage: String {
    var sentences =
      deletion?.deletesServerData ?? false
      ? [
        "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que votre identifiant anonyme.",
        "Votre contribution anonyme au plan des rayons des magasins est conservée.",
        "C'est définitif.",
      ]
      : ["Vos listes et vos visites seront effacées de cet appareil."]
    if interruptsShopping { sentences.append("Vos courses en cours seront interrompues.") }
    return sentences.joined(separator: " ")
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "\(short) (\(build))"
  }
}
