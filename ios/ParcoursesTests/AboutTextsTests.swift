import Foundation
import Testing

@testable import Parcourses

/// Textes qui suivent le compte (#87, lot 87.8), dans À propos et dans la suppression des données, que celle-ci parte
/// d'À propos (compte anonyme) ou de l'écran Compte (compte e-mail, #108). Un compte e-mail n'est jamais purgé pour
/// inactivité.
struct AboutTextsTests {
  @Test func policyLinkPointsToThePublicPage() {
    #expect(PrivacyLinks.policy?.absoluteString == "https://parcourses.hadrien.eu/confidentialite/")
  }

  @Test(arguments: [
    (
      false,
      "Vous pouvez supprimer ces données à tout moment ci-dessous. Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
    ),
    (true, "Vous pouvez supprimer ces données à tout moment depuis l'écran Compte."),
  ])
  func retentionMentionsThePurgeOnlyForAnAnonymousAccount(isEmailAccount: Bool, expected: String) {
    #expect(AboutTexts.retention(isEmailAccount: isEmailAccount) == expected)
  }

  @Test(arguments: [
    (
      true, false,
      "Vous pouvez effacer vos listes, vos visites et votre identifiant anonyme, sur cet appareil et sur nos serveurs."
    ),
    (
      true, true,
      "Vous pouvez effacer vos listes, vos visites et votre compte (adresse e-mail et prénom), sur cet appareil et sur nos serveurs."
    ),
    (false, false, "Vous pouvez effacer vos listes et vos visites de cet appareil."),
    (false, true, "Vous pouvez effacer vos listes et vos visites de cet appareil."),
  ])
  func yourDataFollowsTheAccount(deletesServerData: Bool, isEmailAccount: Bool, expected: String) {
    #expect(
      AccountDeletionTexts.yourData(deletesServerData: deletesServerData, isEmailAccount: isEmailAccount) == expected)
  }

  /// La phrase sur les listes partagées suit celle sur les données effacées, pour les deux comptes.
  @Test(arguments: [
    (
      false,
      "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que votre identifiant anonyme. Une liste que vous partagez avec d'autres passe à l'un de ses membres. Votre contribution anonyme au plan des rayons des magasins est conservée. C'est définitif."
    ),
    (
      true,
      "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que votre compte (adresse e-mail et prénom). Une liste que vous partagez avec d'autres passe à l'un de ses membres. Votre contribution anonyme au plan des rayons des magasins est conservée. C'est définitif."
    ),
  ])
  func serverConfirmationHandsSharedListsOver(isEmailAccount: Bool, expected: String) {
    let message = AccountDeletionTexts.confirmation(
      deletesServerData: true, isEmailAccount: isEmailAccount, interruptsShopping: false)
    #expect(message == expected)
  }

  @Test func confirmationEndsWithTheInterruptedShopping() {
    let message = AccountDeletionTexts.confirmation(
      deletesServerData: true, isEmailAccount: true, interruptsShopping: true)
    #expect(message.hasSuffix("C'est définitif. Vos courses en cours seront interrompues."))
  }

  /// Sans serveur, rien n'est partagé : pas de phrase sur les listes partagées.
  @Test func localConfirmationIsUnchanged() {
    #expect(
      AccountDeletionTexts.confirmation(deletesServerData: false, isEmailAccount: false, interruptsShopping: false)
        == "Vos listes et vos visites seront effacées de cet appareil.")
    #expect(
      AccountDeletionTexts.confirmation(deletesServerData: false, isEmailAccount: false, interruptsShopping: true)
        == "Vos listes et vos visites seront effacées de cet appareil. Vos courses en cours seront interrompues.")
  }

  @Test func deviceOnlyDeletionMentionsThePurgeOnlyForAnAnonymousAccount() {
    #expect(
      AccountDeletionTexts.deletedFromDeviceMessage(isEmailAccount: false)
        == "Celles de nos serveurs seront supprimées après 365 jours sans utilisation.")
    #expect(
      AccountDeletionTexts.deletedFromDeviceMessage(isEmailAccount: true)
        == "Écrivez-nous depuis l'adresse de votre compte : parcourses.hadrien.eu/supprimer-mes-donnees")
  }

  /// Aucun texte montré à un compte e-mail, à À propos comme à l'écran Compte, ne promet la purge d'inactivité.
  @Test(arguments: [false, true])
  func noEmailAccountTextPromisesTheInactivityPurge(deletesServerData: Bool) {
    let texts = [
      AboutTexts.retention(isEmailAccount: true),
      AccountDeletionTexts.yourData(deletesServerData: deletesServerData, isEmailAccount: true),
      AccountDeletionTexts.confirmation(
        deletesServerData: deletesServerData, isEmailAccount: true, interruptsShopping: true),
      AccountDeletionTexts.deletedFromDeviceMessage(isEmailAccount: true),
    ]
    for text in texts {
      #expect(!text.contains("365"), "\(text)")
      #expect(!text.contains("sans utilisation"), "\(text)")
    }
  }
}
