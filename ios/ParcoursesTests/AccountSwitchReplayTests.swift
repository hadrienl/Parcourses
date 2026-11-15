import Foundation
import Supabase
import SwiftData
import Testing

@testable import Parcourses

/// Rejeu de `account.switch` avec la vraie passerelle, hors réseau (relecture de #95) : la session du nouveau compte est
/// lue telle qu'elle est enregistrée, même expirée ou près de l'être, et sans attendre de rafraîchissement.
@MainActor
@Suite(.serialized) struct AccountSwitchReplayTests {
  /// Session e-mail de `id` enregistrée dans le Keychain comme le fait supabase-swift : clé `sb-<hôte>-auth-token`
  /// (`sb-127-auth-token` pour `127.0.0.1`), JSON par défaut.
  private func storeSession(of id: UUID, email: String, expiresAt: Date, in store: MemorySecureStore) throws {
    let user = User(
      id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: email, createdAt: .now,
      updatedAt: .now, isAnonymous: false)
    let session = Session(
      accessToken: "jeton-\(id.uuidString)", tokenType: "bearer", expiresIn: 3600,
      expiresAt: expiresAt.timeIntervalSince1970, refreshToken: "rafraichissement", user: user)
    try store.set(try JSONEncoder().encode(session), forKey: "sb-127-auth-token")
  }

  /// Expirée depuis une heure, ou à 30 s de l'échéance (rafraîchissement imminent ou en cours, serveur injoignable).
  @Test(arguments: [-3600.0, 30.0])
  func theReplaySeesAStoredSessionWhateverItsExpiry(expiresIn: TimeInterval) async throws {
    let defaults = try #require(UserDefaults(suiteName: "tests.switch-replay.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    kinds.save(.email)
    let store = MemorySecureStore()
    let accountB = UUID()
    try storeSession(of: accountB, email: "b@exemple.fr", expiresAt: Date.now.addingTimeInterval(expiresIn), in: store)
    let configuration = try #require(SupabaseConfiguration(url: "http://127.0.0.1:9", publishableKey: "k"))
    let gateway = SupabaseGateway(
      configuration: configuration, store: store,
      deletionFlags: UserDefaultsAccountDeletionFlagStore(defaults: defaults), accountKinds: kinds)
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    _ = try SwiftDataListRepository(context: container.mainContext).createList(name: "De A", at: .now)
    let cursors = UserDefaultsSyncCursors(defaults: defaults)
    cursors.accountId = UUID()
    cursors.accountKind = .email
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: defaults)
    flags.save()
    let session = AccountSession(
      gateway: gateway, kinds: kinds,
      purge: LocalDataPurge(
        container: container, keychain: store, defaults: defaults,
        urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)),
      signOutFlags: UserDefaultsAccountSignOutFlagStore(defaults: defaults), switchFlags: flags, cursors: cursors,
      dependencies: AccountSession.Dependencies(
        link: AccountLink.Dependencies(previousAccountId: { cursors.accountId })))
    #expect(try await gateway.localSessionAccountId() == accountB)
    #expect(try await gateway.accountEmail() == "b@exemple.fr")
    #expect(await session.resumePendingSwitch())
    // B vu malgré l'échéance : les listes de A sont purgées, B devient le compte des données.
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(cursors.accountId == accountB)
    #expect(cursors.accountKind == .email)
    #expect(!flags.isPending)
  }
}
