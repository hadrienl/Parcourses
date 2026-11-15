import SwiftUI

/// Écran Listes : état vide, création, renommage, suppression.
struct ListsView: View {
  @State private var model: ListsModel
  let onOpen: (UUID) -> Void
  /// « Invitations (n) » : écran des invitations reçues.
  let onInvitations: () -> Void

  @State private var isCreating = false
  @State private var renaming: ListSummary?
  @State private var deleting: ListSummary?
  @State private var nameInput = ""
  @State private var showsAbout = false
  @State private var signIn: AccountLink?
  /// Absent sans serveur : aucune entrée de connexion.
  @Environment(AccountSession.self) private var account: AccountSession?
  @Environment(SharingCenter.self) private var sharing: SharingCenter?
  /// Feuille « Membres » d'une liste partagée avec moi, ouverte par « Quitter la liste ».
  @State private var members: ShareListModel?

  init(
    model: ListsModel, onOpen: @escaping (UUID) -> Void,
    onInvitations: @escaping () -> Void = {
      // Sans écran d'invitations : aperçus et tests.
    }
  ) {
    _model = State(initialValue: model)
    self.onOpen = onOpen
    self.onInvitations = onInvitations
  }

  var body: some View {
    content
      .ticketBackground()
      .navigationTitle("Mes listes")
      .toolbar {
        if let account, account.isAvailable, account.kind == .anonymous {
          // Tant que le compte est anonyme (#87, écran 4).
          ToolbarItem(placement: .topBarLeading) {
            Button {
              signIn = account.makeLink()
            } label: {
              Label("Se connecter", systemImage: "person.crop.circle").labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier("signIn")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("À propos", systemImage: "info.circle") { showsAbout = true }
            .accessibilityIdentifier("about")
        }
      }
      .sheet(isPresented: $showsAbout) { AboutView() }
      // Déconnexion interrompue au lancement : À propos fermé, l'alerte vient ici.
      .signOutFailurePresentation(account, isHidden: showsAbout)
      .overlay {
        if account?.isSigningOut == true, !showsAbout { SignOutVeil() }
      }
      .sheet(item: $signIn) { link in
        AccountSignInView(link: link) { Task { await account?.linkDidFinish() } }
      }
      .safeAreaInset(edge: .top) {
        if let account, account.needsSignIn {
          SessionLostBanner(account: account) { signIn = account.makeLink() }
        }
      }
      .safeAreaInset(edge: .bottom) { createButton }
      .opaqueBottomBar()
      // Relancé à chaque retour sur l'écran, pour des compteurs à jour.
      .task { model.load() }
      .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in model.load() }
      .sheet(item: $members) { members in
        if let sharing { ShareListSheet(model: members, center: sharing) }
      }
      .sharingToast(removalMessage, revision: sharing?.removedLists.count ?? 0) {
        if let removed = sharing?.removedLists.first { sharing?.acknowledgeRemoval(removed) }
      }
      .alert("Nouvelle liste", isPresented: $isCreating) {
        TextField("Nom de la liste", text: $nameInput)
        Button("Annuler", role: .cancel) { isCreating = false }
        Button("Créer") {
          if let id = model.create(name: nameInput) { onOpen(id) }
        }
        .disabled(!ListsModel.isValid(name: nameInput))
      }
      .alert("Renommer la liste", isPresented: isPresented($renaming), presenting: renaming) { list in
        TextField("Nom de la liste", text: $nameInput)
        Button("Annuler", role: .cancel) { renaming = nil }
        Button("Renommer") { model.rename(id: list.id, name: nameInput) }
          .disabled(!ListsModel.isValid(name: nameInput))
      }
      .confirmationDialog(
        deletionTitle, isPresented: isPresented($deleting), titleVisibility: .visible, presenting: deleting
      ) { list in
        Button("Supprimer la liste", role: .destructive) { model.delete(id: list.id) }
      } message: { list in
        // Liste partagée : les membres la perdent aussi (maquette, écran 3).
        if list.access.isShared {
          Text("\(ListAccess.sentence(list.access.others.map(\.name))) la perdront aussi. C'est définitif.")
        }
      }
      .alert("Erreur", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
  }

  private var deletionTitle: String {
    guard let deleting, deleting.access.isShared else { return "Supprimer cette liste et ses articles ?" }
    return "Supprimer «\u{00A0}\(deleting.name)\u{00A0}» ?"
  }

  private var removalMessage: String? {
    guard let removed = sharing?.removedLists.first else { return nil }
    return "\(SharingFormat.removedTitle(removed.listName)). Elle a été retirée de cet appareil."
  }

  private var invitations: [ReceivedInvitation] { sharing?.invitations ?? [] }

  @ViewBuilder private var content: some View {
    if model.lists.isEmpty && invitations.isEmpty {
      EmptyState(title: "Aucune liste", systemImage: "cart", description: emptyDescription)
    } else {
      List {
        invitationsEntry
        ForEach(model.lists) { list in
          Button {
            onOpen(list.id)
          } label: {
            row(list)
          }
          .buttonStyle(.plain)
          .ticketRow()
          .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions(for: list) }
          .contextMenu { actions(for: list) }
        }
      }
      .listStyle(.plain)
    }
  }

  /// Compte anonyme : l'invitation attend une connexion avec l'adresse qui l'a reçue (§1.2).
  private var emptyDescription: String {
    if let account, account.isAvailable, account.kind == .anonymous {
      return
        "Créez votre première liste de courses. Vous avez reçu une invitation ? Connectez-vous avec l'adresse qui l'a reçue."
    }
    return "Créez votre première liste de courses."
  }

  /// Une invitation : sa carte en tête. Plusieurs : une ligne « Invitations (n) » (maquette, écran 5).
  @ViewBuilder private var invitationsEntry: some View {
    if let sharing, invitations.count == 1, let invitation = invitations.first {
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("Invitations (1)")
          .font(TicketFont.aisle)
          .tracking(TicketFont.aisleTracking)
          .textCase(.uppercase)
          .foregroundStyle(Palette.inkMuted)
          .accessibilityAddTraits(.isHeader)
        InvitationCard(model: sharing.makeCard(for: invitation), onOpen: onOpen, showsSectionTitle: false)
          .id(invitation.id)
      }
      .padding(.vertical, Space.s)
      .ticketRow()
    } else if invitations.count > 1 {
      Button(action: onInvitations) {
        HStack {
          Label("Invitations (\(invitations.count))", systemImage: "envelope")
            .font(TicketFont.item.weight(.bold))
            .foregroundStyle(Palette.ink)
          Spacer()
          Image(systemName: "chevron.right").foregroundStyle(Palette.inkMuted).accessibilityHidden(true)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .ticketRow()
      .accessibilityIdentifier("invitationsEntry")
    }
  }

  @ViewBuilder private func actions(for list: ListSummary) -> some View {
    if list.access.capabilities.canDeleteList {
      Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = list }
    }
    if list.access.capabilities.canRenameList {
      Button("Renommer", systemImage: "pencil") {
        nameInput = list.name
        renaming = list
      }
    }
    if list.access.capabilities.canLeave, let sharing {
      Button("Quitter la liste", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
        members = sharing.makeShareModel(listId: list.id, listName: list.name)
      }
    }
  }

  private func row(_ list: ListSummary) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: Space.s) {
        VStack(alignment: .leading, spacing: 2) {
          Text(list.name).font(TicketFont.item.weight(.bold)).foregroundStyle(Palette.ink)
          Text(list.subtitle).font(TicketFont.meta).foregroundStyle(Palette.inkMuted)
          if let badge = list.badge {
            HStack(spacing: Space.xs) {
              SharingBadge(kind: badge)
              if list.access.isShared { AvatarStack(labels: list.access.pillLabels, size: 22) }
            }
            .padding(.top, 4)
          }
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(Palette.inkMuted).accessibilityHidden(true)
      }
      .padding(.vertical, Space.s)
      .frame(minHeight: TicketMetrics.rowMin)
      // Filet pointillé du ticket entre deux listes.
      DottedRule()
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    // Liste partagée : libellé de la maquette ; sinon le libellé combiné, inchangé.
    .accessibilityLabel(override: list.badge == nil ? nil : list.accessibilityLabel)
  }

  private var createButton: some View {
    Button {
      nameInput = ""
      isCreating = true
    } label: {
      Label("Nouvelle liste", systemImage: "plus")
        .frame(maxWidth: .infinity)
    }
    .prominentButton()
    // Bouton plein flottant, dans la zone du pouce : pas de barre derrière lui.
    .padding(.horizontal, Space.m)
    .padding(.bottom, Space.xs)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }
}
