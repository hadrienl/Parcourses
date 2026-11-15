import SwiftUI

/// Ce que l'écran Compte demande : les présentations vivent au niveau de l'écran, une feuille ou une alerte posée dans
/// une ligne de `List` étant fragile.
struct AccountPrompts {
  var signIn: AccountLink?
  var confirmsSignOut = false
  var editsName = false
  var nameInput = ""
  var nameFailed = false
  /// Compté après la suspension de la synchro : des entrées (`pending` ou `failed`) restent dans la file.
  var losesChanges = false
}

extension View {
  /// Feuille de reconnexion et alertes de l'écran Compte.
  func accountPrompts(_ prompts: Binding<AccountPrompts>, account: AccountSession?) -> some View {
    modifier(AccountPromptsPresentation(prompts: prompts, account: account))
  }
}

private struct AccountPromptsPresentation: ViewModifier {
  @Binding var prompts: AccountPrompts
  let account: AccountSession?

  func body(content: Content) -> some View {
    content
      .sheet(item: $prompts.signIn) { link in
        AccountSignInView(link: link) { Task { await account?.linkDidFinish() } }
      }
      .alert("Se déconnecter ?", isPresented: $prompts.confirmsSignOut) {
        Button("Se déconnecter", role: .destructive) { Task { await account?.signOut() } }
          .accessibilityIdentifier("confirmSignOut")
        Button("Annuler", role: .cancel) { account?.cancelLeaving() }
      } message: {
        Text(signOutMessage)
      }
      .alert("Prénom", isPresented: $prompts.editsName) {
        TextField("Prénom", text: $prompts.nameInput)
          .textContentType(.givenName)
        Button("Annuler", role: .cancel) {
          // La confirmation se referme, rien d'autre.
        }
        Button("Enregistrer") {
          let input = prompts.nameInput
          Task {
            let saved = await account?.updateDisplayName(input) ?? false
            prompts.nameFailed = !saved
          }
        }
        .disabled(AccountLink.validDisplayName(prompts.nameInput) == nil)
      } message: {
        Text("Les personnes avec qui vous partagez une liste verront ce prénom.")
      }
      .alert("Le prénom n'a pas été enregistré.", isPresented: $prompts.nameFailed) {
        Button("OK", role: .cancel) {
          // Message lu : le prénom reste modifiable.
        }
      } message: {
        Text("Vérifiez votre connexion, puis réessayez. Entre 1 et 40 caractères, sans adresse ni lien.")
      }
  }

  private var signOutMessage: String {
    var sentences = ["Vos listes restent dans votre compte. Elles seront retirées de cet appareil."]
    if prompts.losesChanges {
      sentences.append("Les modifications pas encore envoyées seront perdues.")
    }
    return sentences.joined(separator: " ")
  }
}

extension View {
  /// Purge de la déconnexion en échec : « Réessayer », seule issue. Reportée, elle reprendrait au lancement suivant et
  /// effacerait un compte ouvert entre-temps. `isHidden` : une feuille est ouverte par-dessus, c'est elle qui présente
  /// l'alerte.
  func signOutFailurePresentation(_ account: AccountSession?, isHidden: Bool = false) -> some View {
    modifier(SignOutFailurePresentation(account: account, isHidden: isHidden))
  }
}

private struct SignOutFailurePresentation: ViewModifier {
  let account: AccountSession?
  let isHidden: Bool

  func body(content: Content) -> some View {
    content.alert("La déconnexion n'a pas abouti.", isPresented: isPresented) {
      Button("Réessayer") { Task { await account?.retrySignOut() } }
        .accessibilityIdentifier("retrySignOut")
    } message: {
      Text("Vos listes sont peut-être encore sur cet appareil. Réessayez pour terminer la déconnexion.")
    }
  }

  /// « Réessayer » change l'état du compte : la fermeture de l'alerte n'a rien à écrire.
  private var isPresented: Binding<Bool> {
    Binding(get: { account?.signOutFailed == true && !isHidden }, set: { _ in })
  }
}

/// Bandeau de l'écran Listes : un compte e-mail dont la session a disparu ne crée plus de compte anonyme (vecteur
/// `009`), la synchro attend la reconnexion.
struct SessionLostBanner: View {
  let account: AccountSession
  let onReconnect: () -> Void
  @State private var confirmsAnonymous = false
  @State private var losesChanges = false

  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Label("Reconnectez-vous pour synchroniser.", systemImage: "key")
        .foregroundStyle(Palette.ink)
      Button(action: onReconnect) {
        Text("Se reconnecter").frame(maxWidth: .infinity)
      }
      .prominentButton()
      .accessibilityIdentifier("reconnect")
      Button("Continuer sans compte") {
        Task {
          losesChanges = await account.prepareToLeave()
          confirmsAnonymous = true
        }
      }
      .frame(maxWidth: .infinity)
      .touchTarget()
      .accessibilityIdentifier("continueWithoutAccount")
    }
    .padding(Space.s)
    .background(Palette.paper, in: RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous)
        .strokeBorder(Palette.paperEdge, lineWidth: 1)
    }
    .padding(.horizontal, Space.m)
    .padding(.bottom, Space.xs)
    .alert("Continuer sans compte ?", isPresented: $confirmsAnonymous) {
      Button("Continuer sans compte", role: .destructive) { Task { await account.continueWithoutAccount() } }
        .accessibilityIdentifier("confirmContinueWithoutAccount")
      Button("Annuler", role: .cancel) { account.cancelLeaving() }
    } message: {
      Text(message)
    }
  }

  /// Les listes du compte restent sur le serveur, l'appareil repart vide (README des vecteurs).
  private var message: String {
    var sentences = [
      "Les listes de votre compte seront retirées de cet appareil, mais restent dans votre compte. Vous repartirez avec un compte anonyme vide."
    ]
    if losesChanges { sentences.append("Les modifications pas encore envoyées seront perdues.") }
    return sentences.joined(separator: " ")
  }
}

/// Voile « Déconnexion… », non annulable : la purge de l'appareil suit.
struct SignOutVeil: View {
  var body: some View {
    ZStack {
      Color.black.opacity(0.2).ignoresSafeArea()
      ProgressView("Déconnexion…")
        .padding()
        .parcoursesGlass(in: RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous))
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isModal)
    .accessibilityIdentifier("signOutProgress")
    .onAppear { AccessibilityNotification.Announcement("Déconnexion…").post() }
  }
}
