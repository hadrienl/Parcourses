import SwiftUI

/// Écran Compte d'un compte e-mail (#108 ; maquette `sharing-v1.html`, écran 4 « Compte »), ouvert par la pastille de
/// l'écran Listes : adresse, prénom modifiable, Se déconnecter, Supprimer mes données. Un compte anonyme n'a pas cet
/// écran : son bouton ouvre la connexion. Android : `AccountScreen`.
struct AccountView: View {
  let account: AccountSession
  @Environment(\.dismiss) private var dismiss
  /// Absent dans les aperçus et les tests sans app : la section « Vos données » est alors masquée.
  @Environment(AccountDeletion.self) private var deletion: AccountDeletion?
  @State private var prompts = AccountPrompts()
  @State private var confirmsDeletion = false
  /// Lu à l'ouverture de la confirmation : une visite ouverte ajoute une phrase.
  @State private var interruptsShopping = false
  /// « Se déconnecter » touché, synchro en cours de suspension : l'écran ne se ferme pas avant la confirmation, dont
  /// l'« Annuler » reprend la synchro (sinon elle resterait suspendue jusqu'au lancement suivant).
  @State private var preparesSignOut = false

  var body: some View {
    NavigationStack {
      List {
        // Changement de compte bloqué par une purge qui échoue toujours (#129) : en tête, avant tout le reste.
        if account.isSwitchBlocked {
          SwitchBlockedSection(account: account)
        }
        if account.needsSignIn, !account.isSignOutPending {
          Section {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
              Image(systemName: "key").accessibilityHidden(true)
              Text("Reconnectez-vous pour synchroniser.")
            }
            Button {
              prompts.signIn = account.makeLink()
            } label: {
              Text("Se reconnecter").frame(maxWidth: .infinity, alignment: .leading).touchTarget()
            }
            .disabled(isBlocking)
            .accessibilityIdentifier("accountReconnect")
          }
        }
        Section {
          emailRow
          nameRow
          // Icône et texte côte à côte plutôt qu'un `Label` : dans une ligne de `List`, l'audit d'accessibilité
          // signale le titre d'un `Label` comme rogné aux grandes tailles de texte.
          HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: "lock").accessibilityHidden(true)
            Text("Votre adresse ne sert qu'à vous connecter. Les membres de vos listes voient votre prénom.")
          }
          .font(.footnote)
          .foregroundStyle(Palette.inkMuted)
        }
        if !account.needsSignIn {
          Section {
            signOutButton
          }
        }
        if let deletion {
          YourDataSection(deletion: deletion, isEmailAccount: true, isBlocked: isBlocking) {
            interruptsShopping = deletion.interruptsShopping
            confirmsDeletion = true
          }
        }
      }
      .navigationTitle("Compte")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("OK") { dismiss() }
            .disabled(isBlocking)
            .accessibilityIdentifier("closeAccount")
        }
      }
      .accountDeletionConfirmation(
        $confirmsDeletion, deletion: deletion,
        message: AccountDeletionTexts.confirmation(
          deletesServerData: deletion?.deletesServerData ?? false, isEmailAccount: true,
          interruptsShopping: interruptsShopping))
    }
    // Le message de fin suit le type de compte noté dans le drapeau de suppression (#122), pas `account.kind`, purgé.
    .accountDeletionPresentation(deletion)
    .accountPrompts($prompts, account: account)
    .signOutFailurePresentation(account)
    .overlay {
      if account.isSigningOut { SignOutVeil() }
    }
    // Une fois la requête partie, et tant qu'un doute attend « Réessayer » ou « Annuler », la feuille reste ouverte.
    .interactiveDismissDisabled(isBlocking)
    // Prénom relu sur le serveur à l'ouverture, comme le faisait À propos.
    .task { await account.refresh() }
    // Plus de compte e-mail (déconnexion achevée, « Continuer sans compte ») : rien à montrer ici.
    .onChange(of: account.kind) { _, kind in
      if kind != .email, !isBlocking { dismiss() }
    }
  }

  /// Adresse en lecture, coupée n'importe où aux grandes tailles de texte (maquette, écran 4).
  private var emailRow: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Adresse e-mail").font(.footnote).foregroundStyle(Palette.inkMuted)
      Text(account.email ?? "—")
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(minHeight: TicketMetrics.rowMin, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("accountEmail")
  }

  private var nameRow: some View {
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
    .disabled(isBlocking || account.needsSignIn)
    .accessibilityHint("Modifie le prénom affiché aux membres de vos listes")
    .accessibilityIdentifier("accountName")
  }

  private var signOutButton: some View {
    Button(role: .destructive) {
      // Synchro suspendue avant de compter ce qui reste dans la file.
      preparesSignOut = true
      Task {
        prompts.losesChanges = await account.prepareToLeave()
        prompts.confirmsSignOut = true
        preparesSignOut = false
      }
    } label: {
      HStack(spacing: Space.s) {
        Image(systemName: "rectangle.portrait.and.arrow.right").accessibilityHidden(true)
        Text("Se déconnecter")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .touchTarget()
    }
    .disabled(isBlocking)
    .accessibilityHint("Demande une confirmation avant de retirer vos listes de cet appareil")
    .accessibilityIdentifier("signOut")
  }

  /// Suppression ou déconnexion en cours, ou doute sans réponse : rien ne ferme l'écran sans un choix explicite.
  private var isBlocking: Bool {
    deletion?.status == .deleting || deletion?.status == .failed(.unknown) || account.isSigningOut
      || preparesSignOut || prompts.confirmsSignOut
  }
}
