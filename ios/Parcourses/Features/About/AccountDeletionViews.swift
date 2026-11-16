import SwiftUI

extension View {
  /// Voile « Suppression… » et messages de fin de la suppression du compte (#68 §5.2). `isEmailAccount` est la nature
  /// du compte supprimé, lue avant la purge : celle-ci remet le drapeau `account.kind` à zéro.
  func accountDeletionPresentation(_ deletion: AccountDeletion?, isEmailAccount: Bool) -> some View {
    modifier(AccountDeletionPresentation(deletion: deletion, isEmailAccount: isEmailAccount))
  }
}

/// Issue présentée à la personne. Gardée à part du statut : une alerte qui se ferme ne doit pas réapparaître le temps
/// que l'action lancée par son bouton change le statut.
private struct AccountDeletionOutcome {
  enum Kind {
    /// « OK » : le message est lu, l'app continue (reconstruite après une suppression).
    case acknowledgement
    /// Doute : seuls « Réessayer » et « Annuler » le referment, jamais un geste implicite.
    case doubt
  }

  let kind: Kind
  let title: String
  let message: String?

  /// Textes communs à iOS et Android (#68 §5.2, §5.7, relecture de 68.2 et lot 87.8).
  init?(_ deletion: AccountDeletion, isEmailAccount: Bool) {
    let server = deletion.deletesServerData
    switch deletion.status {
    case .idle, .deleting:
      return nil
    case .deleted:
      kind = .acknowledgement
      title = "Vos données ont été supprimées."
      message = nil
    case .deletedFromDevice:
      kind = .acknowledgement
      title = "Vos données ont été supprimées de cet appareil."
      message = AccountDeletionTexts.deletedFromDeviceMessage(isEmailAccount: isEmailAccount)
    case .failed(.offline):
      kind = .acknowledgement
      title = "Connexion requise."
      message = "Rien n'a été effacé."
    case .failed(.refused):
      kind = .acknowledgement
      title = "La suppression n'a pas abouti."
      message = "Rien n'a été effacé. Réessayez plus tard."
    case .failed(.unknown) where !server:
      kind = .doubt
      title = "La suppression n'a pas abouti."
      message = "Réessayez, ou annulez pour garder ce qui reste sur cet appareil."
    case .failed(.unknown) where deletion.isCancelDeferred:
      kind = .doubt
      title = "La suppression n'a pas pu être confirmée."
      message = "Réessayez dans un instant."
    case .failed(.unknown):
      kind = .doubt
      title = "La suppression n'a pas pu être confirmée."
      message = "Vérifiez votre connexion, puis réessayez. Vos données sont peut-être encore sur nos serveurs."
    }
  }
}

private struct AccountDeletionPresentation: ViewModifier {
  let deletion: AccountDeletion?
  let isEmailAccount: Bool
  @State private var outcome: AccountDeletionOutcome?

  func body(content: Content) -> some View {
    content
      .overlay {
        if deletion?.status == .deleting { AccountDeletionVeil() }
      }
      // Chaque issue publiée, même identique à la précédente (« Réessayez dans un instant »), est présentée.
      .onChange(of: deletion?.revision) {
        outcome = deletion.flatMap { AccountDeletionOutcome($0, isEmailAccount: isEmailAccount) }
      }
      .alert(outcome?.title ?? "", isPresented: isPresented, presenting: outcome) { outcome in
        switch outcome.kind {
        case .doubt:
          Button("Réessayer") { Task { await deletion?.retry() } }
            .accessibilityIdentifier("retryDeletion")
          Button("Annuler", role: .cancel) { Task { await deletion?.cancel() } }
            .accessibilityIdentifier("abandonDeletion")
        case .acknowledgement:
          Button("OK", role: .cancel) { deletion?.acknowledge() }
            .accessibilityIdentifier("acknowledgeDeletion")
        }
      } message: { outcome in
        if let message = outcome.message { Text(message) }
      }
  }

  private var isPresented: Binding<Bool> {
    Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
  }
}

/// Voile bloquant, non annulable : la requête est partie, l'interrompre laisserait un état inconnu.
private struct AccountDeletionVeil: View {
  var body: some View {
    ZStack {
      Color.black.opacity(0.2).ignoresSafeArea()
      ProgressView("Suppression…")
        .padding()
        .parcoursesGlass(in: RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous))
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isModal)
    .accessibilityIdentifier("accountDeletionProgress")
    .onAppear { AccessibilityNotification.Announcement("Suppression de vos données…").post() }
  }
}

/// Lancement avec une suppression inachevée (#68 §5.3) : elle reprend avant tout, l'app normale attend son issue.
struct AccountDeletionResumeView: View {
  let deletion: AccountDeletion
  /// Suppression annulée ou refusée : l'app démarre sur les données gardées.
  let onAbandon: () -> Void
  /// Lu une fois, avant que la reprise ne purge le drapeau `account.kind`.
  @State private var isEmailAccount: Bool

  init(deletion: AccountDeletion, isEmailAccount: Bool, onAbandon: @escaping () -> Void) {
    self.deletion = deletion
    self.onAbandon = onAbandon
    _isEmailAccount = State(initialValue: isEmailAccount)
  }

  var body: some View {
    NavigationStack {
      EmptyState(
        title: "Suppression de vos données", systemImage: "trash",
        description: "La suppression commencée avant la fermeture de l'app reprend."
      )
      .ticketBackground()
    }
    .accountDeletionPresentation(deletion, isEmailAccount: isEmailAccount)
    .task { await deletion.resumeIfNeeded() }
    .onChange(of: deletion.status) { _, status in
      // Après une suppression réussie, `acknowledge()` reconstruit l'app : seul l'abandon passe ici.
      if status == .idle, !deletion.isPending { onAbandon() }
    }
  }
}

/// Section « Vos données » (#68) : dans Compte pour un compte e-mail, dans À propos pour un compte anonyme, qui n'a
/// pas d'écran Compte (#108). La confirmation est posée sur l'écran par `accountDeletionConfirmation`.
struct YourDataSection: View {
  let deletion: AccountDeletion
  let isEmailAccount: Bool
  /// Suppression ou déconnexion en cours : rien d'autre ne se lance.
  let isBlocked: Bool
  let onDelete: () -> Void

  var body: some View {
    Section {
      Text(AccountDeletionTexts.yourData(deletesServerData: deletion.deletesServerData, isEmailAccount: isEmailAccount))
        .accessibilityIdentifier("yourDataDescription")
      Button(role: .destructive, action: onDelete) {
        Text("Supprimer mes données…")
          .frame(maxWidth: .infinity, alignment: .leading)
          .touchTarget()
      }
      .disabled(isBlocked)
      .accessibilityHint("Demande une confirmation avant d'effacer")
      .accessibilityIdentifier("deleteMyData")
    } header: {
      Text("Vos données")
    }
  }
}

/// Textes de la suppression, communs à À propos (compte anonyme) et à Compte (compte e-mail), et à Android (#68 §5.2,
/// §5.7, #108, #87 lot 87.8). Un compte e-mail n'est jamais purgé pour inactivité : seuls les textes d'un compte
/// anonyme parlent des 365 jours.
nonisolated enum AccountDeletionTexts {
  /// Compte e-mail : l'adresse et le prénom partent aussi.
  static func accountWords(isEmailAccount: Bool) -> String {
    isEmailAccount ? "votre compte (adresse e-mail et prénom)" : "votre identifiant anonyme"
  }

  /// Section « Vos données ».
  static func yourData(deletesServerData: Bool, isEmailAccount: Bool) -> String {
    deletesServerData
      ? "Vous pouvez effacer vos listes, vos visites et \(accountWords(isEmailAccount: isEmailAccount)), sur cet appareil et sur nos serveurs."
      : "Vous pouvez effacer vos listes et vos visites de cet appareil."
  }

  /// Message de « Supprimer toutes vos données ? ». Une liste partagée passe à l'un de ses membres (lot 87.8).
  static func confirmation(deletesServerData: Bool, isEmailAccount: Bool, interruptsShopping: Bool) -> String {
    var sentences =
      deletesServerData
      ? [
        "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que \(accountWords(isEmailAccount: isEmailAccount)).",
        "Une liste que vous partagez avec d'autres passe à l'un de ses membres.",
        "Votre contribution anonyme au plan des rayons des magasins est conservée.",
        "C'est définitif.",
      ]
      : ["Vos listes et vos visites seront effacées de cet appareil."]
    if interruptsShopping { sentences.append("Vos courses en cours seront interrompues.") }
    return sentences.joined(separator: " ")
  }

  /// Message sous « Vos données ont été supprimées de cet appareil. » : le compte serveur était hors d'atteinte. Seul un
  /// compte anonyme y sera purgé après 365 jours ; un compte e-mail ne l'est jamais seul, d'où la demande écrite (même
  /// texte qu'Android, `about_account_done_local_body_email`).
  static func deletedFromDeviceMessage(isEmailAccount: Bool) -> String {
    isEmailAccount
      ? "Écrivez-nous depuis l'adresse de votre compte : parcourses.hadrien.eu/supprimer-mes-donnees"
      : "Celles de nos serveurs seront supprimées après 365 jours sans utilisation."
  }
}

extension View {
  /// Alerte « Supprimer toutes vos données ? » de la section « Vos données ».
  func accountDeletionConfirmation(
    _ isPresented: Binding<Bool>, deletion: AccountDeletion?, message: String
  ) -> some View {
    alert("Supprimer toutes vos données ?", isPresented: isPresented) {
      Button("Supprimer", role: .destructive) {
        guard let deletion else { return }
        Task { await deletion.delete() }
      }
      .accessibilityIdentifier("confirmDeletion")
      Button("Annuler", role: .cancel) {}
        .accessibilityIdentifier("cancelDeletion")
    } message: {
      Text(message)
    }
  }
}
