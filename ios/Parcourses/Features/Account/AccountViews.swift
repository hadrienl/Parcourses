import SwiftUI

/// Ce que la section « Compte » demande à l'écran qui la porte : les présentations vivent au niveau de l'écran, une
/// feuille ou une alerte posée dans une ligne de `List` étant fragile.
struct AccountPrompts {
  var signIn: AccountLink?
  var confirmsSignOut = false
  var editsName = false
  var nameInput = ""
  var nameFailed = false
}

extension View {
  /// Feuille de connexion et alertes de la section « Compte ».
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
        Button("Annuler", role: .cancel) {
          // La confirmation se referme, rien d'autre.
        }
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
    if account?.losesPendingChanges == true {
      sentences.append("Les modifications pas encore envoyées seront perdues.")
    }
    return sentences.joined(separator: " ")
  }
}

/// Section « Compte » d'À propos (#87, écran 4) : adresse, prénom modifiable, Se déconnecter ; « Se connecter » pour un
/// compte anonyme. Ses feuilles et alertes sont posées par `accountPrompts` sur l'écran.
struct AccountSection: View {
  let account: AccountSession
  /// Suppression en cours : rien d'autre ne se lance.
  let isBlocked: Bool
  @Binding var prompts: AccountPrompts

  var body: some View {
    Section {
      if account.kind == .email {
        emailRows
      } else {
        Text("Connectez-vous avec votre adresse e-mail pour retrouver vos listes sur un autre appareil.")
        Button {
          prompts.signIn = account.makeLink()
        } label: {
          Label("Se connecter", systemImage: "person.crop.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
            .touchTarget(minHeight: TicketMetrics.rowMin)
        }
        .disabled(isBlocked)
        .accessibilityIdentifier("aboutSignIn")
      }
    } header: {
      Text("Compte")
    }
  }

  @ViewBuilder private var emailRows: some View {
    if account.needsSignIn {
      Text("Reconnectez-vous pour synchroniser.")
      Button {
        prompts.signIn = account.makeLink()
      } label: {
        Text("Se reconnecter").frame(maxWidth: .infinity, alignment: .leading).touchTarget()
      }
      .disabled(isBlocked)
      .accessibilityIdentifier("aboutReconnect")
    }
    VStack(alignment: .leading, spacing: 2) {
      Text("Adresse e-mail").font(.footnote).foregroundStyle(Palette.inkMuted)
      Text(account.email ?? "—")
    }
    .frame(minHeight: TicketMetrics.rowMin, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("accountEmail")
    Button {
      prompts.nameInput = account.displayName ?? ""
      prompts.editsName = true
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Prénom").font(.footnote).foregroundStyle(Palette.inkMuted)
          Text(account.displayName ?? "Ajouter un prénom").foregroundStyle(Palette.ink)
        }
        Spacer()
        Image(systemName: "pencil").foregroundStyle(Palette.accent).accessibilityHidden(true)
      }
      .frame(minHeight: TicketMetrics.rowMin)
      .contentShape(Rectangle())
    }
    .disabled(isBlocked || account.needsSignIn)
    .accessibilityHint("Modifie le prénom affiché aux membres de vos listes")
    .accessibilityIdentifier("accountName")
    Label(
      "Votre adresse ne sert qu'à vous connecter. Les membres de vos listes voient votre prénom.", systemImage: "lock"
    )
    .font(.footnote)
    .foregroundStyle(Palette.inkMuted)
    if !account.needsSignIn {
      Button(role: .destructive) {
        prompts.confirmsSignOut = true
      } label: {
        Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
          .frame(maxWidth: .infinity, alignment: .leading)
          .touchTarget()
      }
      .disabled(isBlocked)
      .accessibilityHint("Demande une confirmation avant de retirer vos listes de cet appareil")
      .accessibilityIdentifier("signOut")
    }
  }
}

/// Bandeau de l'écran Listes : un compte e-mail dont la session a disparu ne crée plus de compte anonyme (vecteur
/// `009`), la synchro attend la reconnexion.
struct SessionLostBanner: View {
  let account: AccountSession
  let onReconnect: () -> Void
  @State private var confirmsAnonymous = false

  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Label("Reconnectez-vous pour synchroniser.", systemImage: "key")
        .foregroundStyle(Palette.ink)
      Button(action: onReconnect) {
        Text("Se reconnecter").frame(maxWidth: .infinity)
      }
      .prominentButton()
      .accessibilityIdentifier("reconnect")
      Button("Continuer sans compte") { confirmsAnonymous = true }
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
      Button("Continuer sans compte", role: .destructive) { account.continueWithoutAccount() }
        .accessibilityIdentifier("confirmContinueWithoutAccount")
      Button("Annuler", role: .cancel) {
        // Le compte reste en attente de reconnexion.
      }
    } message: {
      Text(
        "Les listes partagées avec vous seront retirées de cet appareil. Les vôtres restent ici, sans adresse ni synchronisation entre appareils."
      )
    }
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
