import SwiftUI

/// Textes de la purge qui échoue toujours (#129), communs à iOS et Android.
nonisolated enum PurgeHelpTexts {
  static let signOutTitle = "La déconnexion n'a pas abouti."
  /// Avant le seuil : message inchangé.
  static let signOutMessage =
    "Vos listes sont peut-être encore sur cet appareil. Réessayez pour terminer la déconnexion."
  /// À partir du seuil (`AccountSession.purgeFailureThreshold`).
  static let signOutHelpMessage =
    "Votre appareil manque peut-être d'espace. Libérez-en, puis réessayez. Si le problème continue, supprimez l'app puis réinstallez-la : vos listes restent dans votre compte."
  static let switchBlockedTitle = "Changement de compte inachevé"
  static let switchBlockedMessage =
    "La synchronisation est arrêtée. Votre appareil manque peut-être d'espace. Libérez-en, puis réessayez. Si le problème continue, supprimez l'app puis réinstallez-la : vos listes restent dans votre compte."
  static let retry = "Réessayer"
  static let contact = "Nous écrire"
}

/// Bandeau « Changement de compte inachevé » de l'écran Compte (#129) : drapeau `account.switch` posé et seuil
/// d'échecs atteint. Disparaît dès que le rejeu aboutit (le compteur revient à 0). Android : `account-switch-blocked`.
struct SwitchBlockedSection: View {
  let account: AccountSession
  @Environment(\.openURL) private var openURL
  @State private var isRetrying = false
  /// Aucune app de messagerie : l'adresse s'affiche dans le bandeau.
  @State private var showsAddress = false

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: Space.xs) {
        // Icône et texte côte à côte plutôt qu'un `Label` : titre rogné selon l'audit dans une ligne de `List`.
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
          Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
          Text(PurgeHelpTexts.switchBlockedTitle).font(.headline)
        }
        Text(PurgeHelpTexts.switchBlockedMessage)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, Space.xs)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("switchBlocked")
      Button {
        isRetrying = true
        Task {
          await account.retryPendingSwitch()
          isRetrying = false
        }
      } label: {
        Text(PurgeHelpTexts.retry).frame(maxWidth: .infinity, alignment: .leading).touchTarget()
      }
      .disabled(isRetrying)
      .accessibilityIdentifier("switchBlockedRetry")
      Button {
        openURL(failure.supportMailto) { accepted in
          if !accepted { showsAddress = true }
        }
      } label: {
        Text(PurgeHelpTexts.contact).frame(maxWidth: .infinity, alignment: .leading).touchTarget()
      }
      .accessibilityIdentifier("switchBlockedContact")
      if showsAddress {
        PurgeSupportAddress()
      }
    }
  }

  private var failure: PurgeFailure {
    account.lastPurgeFailure ?? PurgeFailure(operation: .switch, step: .unknown)
  }
}

/// Adresse de contact en texte sélectionnable, quand aucune app de messagerie n'ouvre le `mailto:` (même règle que la
/// demande de suppression d'À propos : le bouton reste, l'adresse s'affiche). Comme Android : l'adresse seule.
struct PurgeSupportAddress: View {
  var body: some View {
    Text(PurgeFailure.supportAddress)
      .bold()
      .textSelection(.enabled)
      .frame(minHeight: TicketMetrics.rowMin, alignment: .leading)
      .accessibilityIdentifier("supportAddress")
  }
}

/// Feuille de l'adresse, ouverte depuis l'alerte de la déconnexion : une alerte ne montre pas de texte sélectionnable.
/// Fermée, l'alerte revient.
struct PurgeSupportSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        PurgeSupportAddress()
      }
      .navigationTitle(PurgeHelpTexts.contact)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("OK") { dismiss() }
            .accessibilityIdentifier("closeSupportAddress")
        }
      }
    }
  }
}
