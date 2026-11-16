import Testing

@testable import Parcourses

/// Bouton compte de Mes listes (#108) : mêmes cas qu'Android (`AccountEntryTest`).
@MainActor struct AccountEntryTests {
  @Test func anAnonymousAccountOffersToSignIn() {
    #expect(AccountEntry.of(kind: .anonymous, displayName: nil) == .signIn)
    // Un prénom resté d'un ancien compte ne change rien : l'anonyme se connecte.
    #expect(AccountEntry.of(kind: .anonymous, displayName: "Hadrien") == .signIn)
  }

  @Test(arguments: [
    ("Hadrien", "H"),
    ("  léa ", "L"),
    ("élodie", "É"),
    ("Ölaf", "Ö"),
  ])
  func anEmailAccountShowsTheInitialOfTheFirstName(name: String, initial: String) {
    #expect(AccountEntry.of(kind: .email, displayName: name) == .account(initial: initial))
  }

  @Test(arguments: [nil, "", "   "])
  func anEmailAccountWithoutAFirstNameHasNoInitial(name: String?) {
    #expect(AccountEntry.of(kind: .email, displayName: name) == .account(initial: nil))
  }

  @Test func theSpokenLabelNamesTheAccountAndTheLostSession() {
    #expect(AccountEntry.accountLabel(displayName: "Hadrien", needsSignIn: false) == "Compte, Hadrien")
    #expect(AccountEntry.accountLabel(displayName: " ", needsSignIn: false) == "Compte")
    #expect(
      AccountEntry.accountLabel(displayName: "Hadrien", needsSignIn: true)
        == "Compte, Hadrien. Reconnectez-vous pour synchroniser")
  }

  @Test func theDeletionConfirmationNamesTheEmailAccount() {
    let email = AccountDeletionTexts.confirmation(
      deletesServerData: true, isEmailAccount: true, interruptsShopping: false)
    #expect(email.contains("votre compte (adresse e-mail et prénom)"))
    let anonymous = AccountDeletionTexts.confirmation(
      deletesServerData: true, isEmailAccount: false, interruptsShopping: true)
    #expect(anonymous.contains("votre identifiant anonyme"))
    #expect(anonymous.hasSuffix("Vos courses en cours seront interrompues."))
    #expect(
      AccountDeletionTexts.confirmation(deletesServerData: false, isEmailAccount: false, interruptsShopping: false)
        == "Vos listes et vos visites seront effacées de cet appareil.")
  }
}
