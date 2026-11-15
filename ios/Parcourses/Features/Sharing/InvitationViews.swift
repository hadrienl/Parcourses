import SwiftUI

/// Carte d'une invitation reçue (maquette, écran 5) : « Hadrien vous invite à « Courses de la semaine » », accès et
/// échéance, puis Refuser / Accepter. Lue comme un seul élément, suivi des deux boutons.
struct InvitationCard: View {
  @State var model: InvitationCardModel
  /// Liste acceptée et descendue : à ouvrir.
  let onOpen: (UUID) -> Void
  /// « Se connecter » (compte anonyme) ou « Changer de compte » (autre adresse).
  var onSignIn: () -> Void = {
    // Sans parcours de connexion.
  }
  /// « Fermer » d'un état sans action (feuille ouverte par un lien).
  var onClose: (() -> Void)?
  var showsSectionTitle = true

  @State private var confirmsDecline = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous)
    VStack(alignment: .leading, spacing: Space.s) {
      if showsSectionTitle {
        Text("Invitation")
          .font(TicketFont.aisle)
          .tracking(TicketFont.aisleTracking)
          .textCase(.uppercase)
          .foregroundStyle(Palette.inkMuted)
          .accessibilityHidden(true)
      }
      content
    }
    .padding(Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.paper, in: shape)
    .overlay { shape.strokeBorder(Palette.accent, lineWidth: 1.5) }
    .task { if model.phase == .loading { await model.load() } }
    .alert("Refuser l'invitation ?", isPresented: $confirmsDecline) {
      Button("Annuler", role: .cancel) { confirmsDecline = false }
      Button("Refuser", role: .destructive) { Task { _ = await model.decline() } }
        .accessibilityIdentifier("confirmDecline")
    } message: {
      Text(
        "Elle disparaîtra. \(SharingFormat.inviterName(model.inviterName)) pourra vous en envoyer une autre.")
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 80)
    case .accepting:
      HStack(spacing: Space.s) {
        ProgressView()
        Text("Ouverture de la liste…").foregroundStyle(Palette.ink)
      }
      .frame(minHeight: 50)
      .onAppear { AccessibilityNotification.Announcement("Ouverture de la liste…").post() }
    case .signInRequired:
      messageView
      primaryButton("Se connecter", identifier: "invitationSignIn", action: onSignIn)
    case .offline, .failed:
      messageView
      primaryButton("Réessayer", identifier: "invitationRetry") { Task { await model.retry() } }
    case .ready:
      readyContent
    }
  }

  @ViewBuilder private var readyContent: some View {
    switch model.state {
    case .acceptable:
      summary
      actions(acceptLabel: "Accepter")
    case .otherAddress:
      CautionCard {
        Label {
          Text("Cette invitation était pour une autre adresse").bold().accessibilityAddTraits(.isHeader)
        } icon: {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.Sharing.caution)
        }
        Text(model.otherAddressBody)
      }
      summary
      primaryButton("Accepter avec ce compte", identifier: "acceptInvitation") { accept() }
      Button("Changer de compte", action: onSignIn)
        .frame(maxWidth: .infinity)
        .touchTarget()
    case .alreadyMember, .used, .expired, .invalid, .rateLimited:
      messageView
      if let onClose { primaryButton("Fermer", identifier: "closeInvitation", action: onClose) }
    }
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: Space.s) {
      MemberAvatar(label: model.inviterInitial, size: 36, ring: false, scalesWithText: true)
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(model.title)
          .font(TicketFont.item.weight(.bold))
          .foregroundStyle(Palette.ink)
          .fixedSize(horizontal: false, vertical: true)
        Text(model.meta(abbreviated: typeSize < .accessibility1))
          .font(TicketFont.meta)
          .foregroundStyle(Palette.inkMuted)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.accessibilityLabel)
    .accessibilityIdentifier("invitationCard")
  }

  @ViewBuilder private var messageView: some View {
    if let message = model.message {
      Text(message)
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("invitationMessage")
    }
  }

  /// Refuser à gauche, Accepter à droite (pouce) ; empilés aux grandes tailles, Accepter en premier.
  @ViewBuilder private func actions(acceptLabel: String) -> some View {
    let layout =
      typeSize >= .accessibility1
      ? AnyLayout(VStackLayout(spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.xs))
    layout {
      if typeSize >= .accessibility1 { acceptButton(acceptLabel) }
      if model.canDecline {
        Button {
          confirmsDecline = true
        } label: {
          Text("Refuser").frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
        .font(.body.weight(.bold))
        .foregroundStyle(Palette.ink)
        .background(Palette.paperEdge, in: Capsule())
        .accessibilityIdentifier("declineInvitation")
      }
      if typeSize < .accessibility1 { acceptButton(acceptLabel) }
    }
  }

  private func acceptButton(_ label: String) -> some View {
    Button(action: accept) {
      Text(label).frame(maxWidth: .infinity)
    }
    .prominentButton()
    .accessibilityIdentifier("acceptInvitation")
  }

  private func primaryButton(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label).frame(maxWidth: .infinity)
    }
    .prominentButton()
    .accessibilityIdentifier(identifier)
  }

  private func accept() {
    Task {
      if let listId = await model.accept() { onOpen(listId) }
    }
  }
}

/// Feuille d'une invitation ouverte par son lien (`parcourses://invitation#<jeton>`). Un compte anonyme se connecte
/// d'abord ; le jeton attend en mémoire, puis la carte se recharge.
struct InvitationLinkSheet: View {
  @State var model: InvitationCardModel
  let center: SharingCenter
  let onOpen: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(AccountSession.self) private var account: AccountSession?
  @State private var signIn: AccountLink?

  var body: some View {
    NavigationStack {
      ScrollView {
        InvitationCard(
          model: model,
          onOpen: { listId in
            dismiss()
            onOpen(listId)
          }, onSignIn: { signIn = account?.makeLink() }, onClose: { dismiss() }, showsSectionTitle: false
        )
        .id(model.id)
        .padding(Space.m)
      }
      .ticketBackground()
      .navigationTitle("Invitation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
            .accessibilityIdentifier("closeInvitationSheet")
        }
      }
      .sheet(item: $signIn) { link in
        AccountSignInView(link: link, context: .invitation) {
          Task {
            await account?.linkDidFinish()
            await center.foreground()
            await model.load()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Écran « Invitations (n) » : toutes les invitations reçues, quand il y en a plusieurs.
struct ReceivedInvitationsScreen: View {
  let center: SharingCenter
  let onOpen: (UUID) -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: Space.m) {
        ForEach(center.invitations) { invitation in
          InvitationCard(model: center.makeCard(for: invitation), onOpen: onOpen, showsSectionTitle: false)
            .id(invitation.id)
        }
        if center.invitations.isEmpty {
          let none = SharingFormat.noInvitation(email: center.dependencies.accountEmail())
          VStack(alignment: .leading, spacing: Space.xs) {
            Text(none.title).font(.body.weight(.bold)).foregroundStyle(Palette.ink)
            Text(none.body).foregroundStyle(Palette.inkMuted)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("noInvitation")
        }
      }
      .padding(Space.m)
    }
    .ticketBackground()
    .navigationTitle("Invitations")
    .task { await center.loadInvitations() }
    .refreshable { await center.loadInvitations() }
  }
}
