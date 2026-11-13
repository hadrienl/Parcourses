import SwiftUI

extension View {
  /// Voile « Suppression… » et messages de fin de la suppression du compte (#68 §5.2).
  func accountDeletionPresentation(_ deletion: AccountDeletion?) -> some View {
    modifier(AccountDeletionPresentation(deletion: deletion))
  }
}

/// Issue présentée à la personne. Gardée à part du statut : une alerte qui se ferme ne doit pas réapparaître le temps
/// que l'action lancée par son bouton change le statut.
private enum AccountDeletionOutcome: Identifiable {
  case deleted
  case failed(AccountDeletionError)

  var id: String {
    switch self {
    case .deleted: "deleted"
    case .failed(let error): "\(error)"
    }
  }

  init?(_ status: AccountDeletion.Status) {
    switch status {
    case .deleted: self = .deleted
    case .failed(let error): self = .failed(error)
    case .idle, .deleting: return nil
    }
  }

  var title: String {
    switch self {
    case .deleted: "Vos données ont été supprimées."
    case .failed(.offline): "Connexion requise."
    case .failed(.refused): "La suppression n'a pas abouti."
    case .failed(.unknown): "La suppression n'a pas pu être confirmée."
    }
  }

  var message: String? {
    switch self {
    case .deleted: nil
    case .failed(.offline): "Rien n'a été effacé."
    case .failed(.refused): "Rien n'a été effacé. Réessayez plus tard."
    case .failed(.unknown):
      "Vos données sont peut-être encore sur nos serveurs. Réessayez, ou annulez pour les garder si elles y sont."
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
      .onChange(of: deletion?.status) { _, status in
        outcome = status.flatMap(AccountDeletionOutcome.init)
      }
      .alert(outcome?.title ?? "", isPresented: isPresented, presenting: outcome) { outcome in
        switch outcome {
        case .failed(.unknown):
          Button("Réessayer") { Task { await deletion?.retry() } }
            .accessibilityIdentifier("retryDeletion")
          Button("Annuler", role: .cancel) { Task { await deletion?.cancel() } }
            .accessibilityIdentifier("abandonDeletion")
        case .deleted, .failed:
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
