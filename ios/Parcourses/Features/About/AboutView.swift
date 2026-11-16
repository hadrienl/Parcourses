import SwiftUI

/// À propos : attribution des données, confidentialité, version. Rien sur le compte (#108) : l'adresse, le prénom et
/// la déconnexion sont dans l'écran Compte. Seul un compte anonyme, qui n'a pas d'écran Compte, trouve ici « Vos
/// données » (#68).
struct AboutView: View {
  @Environment(\.dismiss) private var dismiss
  /// Absent dans les aperçus et les tests sans app : la section « Vos données » est alors masquée.
  @Environment(AccountDeletion.self) private var deletion: AccountDeletion?
  /// Absent sans serveur, dans les aperçus et les tests : le texte de confidentialité est celui d'un compte anonyme.
  @Environment(AccountSession.self) private var account: AccountSession?
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
            "Pour apprendre l'ordre des rayons, Parcourses enregistre vos listes, les magasins où vous faites vos courses, l'heure de vos visites et les articles que vous cochez. "
              + (isEmailAccount
                ? "Ces données sont rattachées à votre compte : votre adresse e-mail ne sert qu'à vous connecter, et seul votre prénom est montré aux membres de vos listes."
                : "Ces données sont rattachées à un identifiant anonyme, sans nom ni e-mail.")
          )
          Text(
            "Les noms d'articles que vous saisissez restent privés. Un nom ne rejoint le catalogue commun, sans lien avec vous, qu'une fois saisi par au moins trois personnes."
          )
          Text(
            "Seule votre position GPS n'est pas conservée : elle sert une seule fois à trouver le magasin où vous êtes, puis elle est oubliée."
          )
          if deletion?.deletesServerData == true {
            Text(AboutTexts.retention(isEmailAccount: isEmailAccount))
              .accessibilityIdentifier("aboutRetention")
          }
          // Exigé par l'App Review (5.1.1(i)), pour tous les comptes, même dans un build sans serveur (lot 87.8).
          if let url = PrivacyLinks.policy {
            Link(destination: url) {
              Text("Politique de confidentialité").touchTarget()
            }
            .accessibilityHint("Ouvre la politique de confidentialité dans le navigateur")
            .accessibilityIdentifier("aboutPrivacyPolicyLink")
          }
        } header: {
          Text("Confidentialité")
        }
        if let deletion, !isEmailAccount {
          YourDataSection(deletion: deletion, isEmailAccount: false, isBlocked: isBlocking) {
            interruptsShopping = deletion.interruptsShopping
            confirmsDeletion = true
          }
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
      .accountDeletionConfirmation(
        $confirmsDeletion, deletion: deletion,
        message: AccountDeletionTexts.confirmation(
          deletesServerData: deletion?.deletesServerData ?? false, isEmailAccount: false,
          interruptsShopping: interruptsShopping))
    }
    // « Vos données » n'est ici que pour un compte anonyme : un compte e-mail supprime ses données depuis Compte.
    .accountDeletionPresentation(deletion, isEmailAccount: false)
    // Purge de déconnexion en cours ou en échec (« Continuer sans compte », reprise au lancement) : À propos ouvert
    // par-dessus Mes listes porte le voile et l'alerte, que Mes listes masque alors.
    .signOutFailurePresentation(account)
    .overlay {
      if account?.isSigningOut == true { SignOutVeil() }
    }
    // Une fois la requête partie, et tant qu'un doute attend « Réessayer » ou « Annuler », la feuille reste ouverte.
    .interactiveDismissDisabled(isBlocking)
  }

  /// Suppression ou déconnexion en cours, ou doute sans réponse : rien ne ferme l'écran sans un choix explicite.
  private var isBlocking: Bool {
    deletion?.status == .deleting || deletion?.status == .failed(.unknown) || account?.isSigningOut == true
  }

  /// Sans serveur, pas d'écran Compte : « Vos données » reste ici, quel que soit le drapeau `account.kind`.
  private var isEmailAccount: Bool { account?.isAvailable == true && account?.kind == .email }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "\(short) (\(build))"
  }
}
