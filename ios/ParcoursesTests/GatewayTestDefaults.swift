import Foundation

@testable import Parcourses

/// Doublures qui ne servent ni la synchro des articles ni les comptes (#87) : tout échoue comme sans session. Les
/// doublures de la synchro (`ScriptedSyncGateway`, `DeletionGateway`) et du compte (`AccountGateway`) les implémentent.
extension RemoteGateway {
  func insertItem(_ item: ListItemUpsert) async throws { throw RemoteError.unauthorized }
  func updateItem(id: UUID, fields: ListItemFields) async throws -> Bool { throw RemoteError.unauthorized }
  func deleteItem(id: UUID) async throws -> Bool { throw RemoteError.unauthorized }
  func fetchItems(listId: UUID) async throws -> [ListItemRow] { throw RemoteError.unauthorized }
  func fetchItemIds(listId: UUID) async throws -> [UUID] { throw RemoteError.unauthorized }
  func accessibleListIds() async throws -> [UUID] { throw RemoteError.unauthorized }
  func fetchTombstones(after: Date?) async throws -> [TombstoneRow] { throw RemoteError.unauthorized }
  func fetchTombstones(ids: [UUID]) async throws -> [TombstoneRow] { throw RemoteError.unauthorized }
  func accountEmail() async throws -> String? { nil }
  func linkEmail(_ email: String) async throws { throw RemoteError.unauthorized }
  func signInWithEmail(_ email: String) async throws { throw RemoteError.unauthorized }
  func verifyCode(email: String, code: String, purpose: EmailCodePurpose) async throws -> VerifiedCode {
    throw RemoteError.unauthorized
  }
  func displayName() async throws -> String? { throw RemoteError.unauthorized }
  func setDisplayName(_ name: String) async throws { throw RemoteError.unauthorized }
  func signOut() async throws { throw RemoteError.unauthorized }
  func deleteAccount(accessToken: String) async throws { throw RemoteError.unauthorized }
}
