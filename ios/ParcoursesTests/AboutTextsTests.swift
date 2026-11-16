import Foundation
import Testing

@testable import Parcourses

/// Textes de l'écran À propos selon le compte (#87, lot 87.8) : un compte e-mail n'est jamais purgé pour inactivité.
struct AboutTextsTests {
  @Test func policyLinkPointsToThePublicPage() {
    #expect(PrivacyLinks.policy?.absoluteString == "https://parcourses.hadrien.eu/confidentialite/")
  }

  @Test(arguments: [
    (
      false,
      "Vous pouvez supprimer ces données à tout moment ci-dessous. Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
    ),
    (true, "Vous pouvez supprimer ces données à tout moment ci-dessous."),
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
    #expect(AboutTexts.yourData(deletesServerData: deletesServerData, isEmailAccount: isEmailAccount) == expected)
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
    let message = AboutTexts.confirmation(
      deletesServerData: true, isEmailAccount: isEmailAccount, interruptsShopping: false)
    #expect(message == expected)
  }

  @Test func confirmationEndsWithTheInterruptedShopping() {
    let message = AboutTexts.confirmation(deletesServerData: true, isEmailAccount: true, interruptsShopping: true)
    #expect(message.hasSuffix("C'est définitif. Vos courses en cours seront interrompues."))
  }

  /// Sans serveur, rien n'est partagé : pas de phrase sur les listes partagées.
  @Test func localConfirmationIsUnchanged() {
    #expect(
      AboutTexts.confirmation(deletesServerData: false, isEmailAccount: false, interruptsShopping: false)
        == "Vos listes et vos visites seront effacées de cet appareil.")
    #expect(
      AboutTexts.confirmation(deletesServerData: false, isEmailAccount: false, interruptsShopping: true)
        == "Vos listes et vos visites seront effacées de cet appareil. Vos courses en cours seront interrompues.")
  }

  @Test func deviceOnlyDeletionMentionsThePurgeOnlyForAnAnonymousAccount() {
    #expect(
      AboutTexts.deletedFromDeviceMessage(isEmailAccount: false)
        == "Celles de nos serveurs seront supprimées après 365 jours sans utilisation.")
    #expect(
      AboutTexts.deletedFromDeviceMessage(isEmailAccount: true)
        == "Écrivez-nous depuis l'adresse de votre compte : parcourses.hadrien.eu/supprimer-mes-donnees")
  }
}
