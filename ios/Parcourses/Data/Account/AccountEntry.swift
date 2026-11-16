import Foundation

/// Bouton compte de l'écran Listes (#108), toujours visible. Même nom et mêmes cas sur Android.
/// - `signIn` : compte anonyme, « Se connecter » ouvre la liaison ou la connexion ;
/// - `account(initial:)` : compte e-mail, la pastille de l'initiale du prénom ouvre l'écran Compte. `nil` sans prénom :
///   une icône de personne la remplace (jamais « ? »).
nonisolated enum AccountEntry: Equatable, Sendable {
  case signIn
  case account(initial: String?)

  static func of(kind: AccountKind, displayName: String?) -> AccountEntry {
    guard kind == .email else { return .signIn }
    let name = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return .account(initial: name.isEmpty ? nil : SharingDecisions.memberInitial(name))
  }

  /// Libellé lu du bouton : « Compte, Hadrien », et l'invitation à se reconnecter si la session a disparu.
  static func accountLabel(displayName: String?, needsSignIn: Bool) -> String {
    let name = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var label = name.isEmpty ? "Compte" : "Compte, \(name)"
    if needsSignIn { label += ". Reconnectez-vous pour synchroniser" }
    return label
  }
}
