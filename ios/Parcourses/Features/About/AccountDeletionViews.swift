import SwiftUI

extension View {
  /// Voile « Suppression… » et messages de fin de la suppression du compte (#68 §5.2).
  func accountDeletionPresentation(_ deletion: AccountDeletion?) -> some View {
    modifier(AccountDeletionPresentation(deletion: deletion))
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

  /// Textes communs à iOS et Android (#68 §5.2, §5.7 et relecture de 68.2).
  init?(_ deletion: AccountDeletion) {
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
      message = "Celles de nos serveurs seront supprimées après 365 jours sans utilisation."
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
  @State private var outcome: AccountDeletionOutcome?

  func body(content: Content) -> some View {
    content
      .overlay {
        if deletion?.status == .deleting { AccountDeletionVeil() }
      }
      // Chaque issue publiée, même identique à la précédente (« Réessayez dans un instant »), est présentée.
      .onChange(of: deletion?.revision) {
        outcome = deletion.flatMap(AccountDeletionOutcome.init)
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

  var body: some View {
    NavigationStack {
      EmptyState(
        title: "Suppression de vos données", systemImage: "trash",
        description: "La suppression commencée avant la fermeture de l'app reprend."
      )
      .ticketBackground()
    }
    .accountDeletionPresentation(deletion)
    .task { await deletion.resumeIfNeeded() }
    .onChange(of: deletion.status) { _, status in
      // Après une suppression réussie, `acknowledge()` reconstruit l'app : seul l'abandon passe ici.
      if status == .idle, !deletion.isPending { onAbandon() }
    }
  }
}
