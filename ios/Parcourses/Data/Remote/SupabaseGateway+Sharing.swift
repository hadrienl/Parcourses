import Foundation
import Supabase

// Partage d'une liste (#87, lot 87.4) : RPC du lot 87.2, Edge Function `send-invitation` et canal temps réel.
extension SupabaseGateway {
  // MARK: - Invitations

  func sendInvitation(listId: UUID, email: String, role: ListRole) async throws -> SentInvitation {
    try await sharing {
      let token = try await self.client.auth.session.accessToken
      var request = URLRequest(url: self.sendInvitationURL)
      request.httpMethod = "POST"
      request.timeoutInterval = 20
      request.setValue(self.publishableKey, forHTTPHeaderField: "apikey")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(SendInvitationBody(listId: listId, email: email, role: role.rawValue))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw SharingRequestError(error: "rpc_failed") }
      guard (200..<300).contains(http.statusCode) else {
        // Erreur relayée par la fonction (`{ error, code }`) ; sans corps lisible, seul le statut parle.
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        throw SharingRequestError(
          error: body?["error"] as? String ?? (http.statusCode == 401 ? "unauthorized" : "rpc_failed"))
      }
      let wire = try PostgrestClient.Configuration.jsonDecoder.decode(SentInvitationWire.self, from: data)
      return SentInvitation(
        invitationId: wire.invitationId, link: wire.link, sent: wire.sent, expiresAt: wire.expiresAt)
    }
  }

  func invitationLink(listId: UUID, email: String, role: ListRole) async throws -> String {
    try await sharing {
      let rows: [CreatedInvitationRow] =
        try await self.rest.rpc(
          "create_invitation",
          params: SharingRPCParameters(listId: listId, email: email, role: role.rawValue, sendEmail: false)
        ).execute().value
      guard let row = rows.first else { throw SharingRequestError(error: "rpc_failed") }
      return self.invitationLinks.link(token: row.token)
    }
  }

  func revokeInvitation(id: UUID) async throws {
    try await sharing {
      _ = try await self.rest.rpc("revoke_invitation", params: SharingRPCParameters(invitationId: id)).execute()
    }
  }

  func listSharing(listId: UUID) async throws -> ListSharing {
    // Erreurs classées comme la synchro : `forbidden` (42501) dit que la liste n'est plus lisible (`refreshAccess`).
    try await authorized {
      let wire: ListSharingWire =
        try await self.rest.rpc("list_sharing", params: SharingRPCParameters(listId: listId)).execute().value
      return wire.model
    }
  }

  func myInvitations() async throws -> [ReceivedInvitation] {
    try await sharing {
      let rows: [ReceivedInvitationRow] = try await self.rest.rpc("my_invitations").execute().value
      return rows.map(\.model)
    }
  }

  func previewInvitation(token: String) async throws -> InvitationPreview {
    try await sharing {
      let rows: [InvitationPreviewRow] =
        try await self.rest.rpc("preview_invitation", params: SharingRPCParameters(token: token)).execute().value
      guard let row = rows.first else { throw SharingRequestError(error: "rpc_failed") }
      return row.model
    }
  }

  func acceptInvitation(token: String) async throws -> InvitationAcceptance {
    try await accept(SharingRPCParameters(token: token))
  }

  func acceptInvitation(id: UUID) async throws -> InvitationAcceptance {
    try await accept(SharingRPCParameters(invitationId: id))
  }

  func declineInvitation(id: UUID) async throws {
    try await sharing {
      _ = try await self.rest.rpc("decline_invitation", params: SharingRPCParameters(invitationId: id)).execute()
    }
  }

  func setMemberRole(listId: UUID, userId: UUID, role: ListRole) async throws {
    try await sharing {
      _ = try await self.rest.rpc(
        "set_member_role", params: SharingRPCParameters(listId: listId, userId: userId, role: role.rawValue)
      ).execute()
    }
  }

  func removeMember(listId: UUID, userId: UUID) async throws {
    try await sharing {
      _ = try await self.rest.rpc("remove_member", params: SharingRPCParameters(listId: listId, userId: userId))
        .execute()
    }
  }

  // MARK: - Descente des membres

  func fetchListMembers() async throws -> [ListMemberRow] {
    try await authorized {
      try await self.fetchAllPages { from, to in
        try await self.rest.from(ListMemberRow.table).select(Self.selection(of: ListMemberRow.self))
          .order("list_id").order("user_id").range(from: from, to: to).execute().value
      }
    }
  }

  func fetchProfiles() async throws -> [ProfileRow] {
    try await authorized {
      try await self.fetchAllPages { from, to in
        try await self.rest.from(ProfileRow.table).select(Self.selection(of: ProfileRow.self))
          .order("user_id").range(from: from, to: to).execute().value
      }
    }
  }

  // MARK: - Outils

  private func accept(_ parameters: SharingRPCParameters) async throws -> InvitationAcceptance {
    try await sharing {
      let rows: [InvitationAcceptanceRow] =
        try await self.rest.rpc("accept_invitation", params: parameters).execute().value
      guard let row = rows.first else { throw SharingRequestError(error: "rpc_failed") }
      return row.model
    }
  }

  /// Session exigée, jamais créée ; les erreurs deviennent `SharingRequestError` (vecteur `003`).
  private func sharing<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    do {
      _ = try await resolveExistingSession()
      return try await operation()
    } catch {
      throw Self.sharingError(error)
    }
  }

  /// Erreur d'une action de partage, au format de l'entrée du vecteur `003`.
  static func sharingError(_ error: any Error) -> SharingRequestError {
    switch error {
    case let error as SharingRequestError:
      return error
    case let error as PostgrestError:
      // `P0001` : message stable de la RPC (invalid_email, list_full…). `42501` : « not allowed », ou un compte sans
      // adresse confirmée (« email account required »), à qui l'on propose de se connecter.
      if error.code == "42501" {
        return SharingRequestError(error: error.message == "not allowed" ? "not allowed" : "unauthorized")
      }
      return SharingRequestError(error: error.code == "P0001" ? error.message : "rpc_failed")
    default:
      switch classify(error) {
      case .network: return SharingRequestError(error: nil)
      case .unauthorized, .accountChanged, .keychainLocked: return SharingRequestError(error: "unauthorized")
      case .forbidden: return SharingRequestError(error: "not allowed")
      default: return SharingRequestError(error: "rpc_failed")
      }
    }
  }
}

// MARK: - Temps réel

extension SupabaseGateway: RealtimeTransport {
  /// Événement des signaux émis par la base (`realtime.send(…, 'changed', 'user:<uid>', true)`).
  static let signalEvent = "changed"

  func userSignals(userId: UUID) async -> AsyncStream<RealtimeEvent> {
    await closeUserSignals()
    let channel = client.realtimeV2.channel("user:\(userId.uuidString.lowercased())") { $0.isPrivate = true }
    signalChannel = channel
    let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
    // Abonnements posés avant de rejoindre le canal : aucun signal ni changement d'état n'est perdu.
    let broadcasts = channel.broadcastStream(event: Self.signalEvent)
    let statuses = channel.statusChange
    let relay = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await status in statuses where status == .subscribed { continuation.yield(.subscribed) }
        }
        group.addTask {
          for await message in broadcasts {
            if let signal = Self.signal(from: message) { continuation.yield(.signal(signal)) }
          }
        }
        group.addTask {
          do {
            try await channel.subscribeWithError()
          } catch {
            // Refus ou délai dépassé : le flux se termine, `RealtimeSignals` réessaiera.
            continuation.finish()
          }
        }
      }
    }
    signalRelay = relay
    signalContinuation = continuation
    continuation.onTermination = { _ in relay.cancel() }
    return stream
  }

  func closeUserSignals() async {
    signalRelay?.cancel()
    signalRelay = nil
    // Flux terminé : l'écoute de `RealtimeSignals` sort de sa boucle au lieu d'attendre un événement qui ne viendra plus.
    signalContinuation?.finish()
    signalContinuation = nil
    guard let channel = signalChannel else { return }
    signalChannel = nil
    // Dernier canal retiré : le client ferme aussi le WebSocket.
    await client.realtimeV2.removeChannel(channel)
  }

  /// Charge utile `{ list_id, kind }` d'un message de diffusion ; `nil` si elle est illisible.
  static func signal(from message: JSONObject) -> RealtimeSignal? {
    guard let payload = message["payload"]?.objectValue, let kind = payload["kind"]?.stringValue else { return nil }
    return RealtimeSignal(listId: payload["list_id"]?.stringValue.flatMap(UUID.init(uuidString:)), kind: kind)
  }
}
