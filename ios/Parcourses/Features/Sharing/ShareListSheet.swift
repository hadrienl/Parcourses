import SwiftUI

/// Feuille « Partager la liste » (propriétaire) ou « Membres » (membre) : maquette `design/sharing-v1.html`, écrans 2
/// et 3. Détente `.large`, fermeture par ✕.
struct ShareListSheet: View {
  @State private var model: ShareListModel
  let center: SharingCenter
  @Environment(\.dismiss) private var dismiss
  @FocusState private var emailFocused: Bool
  @AccessibilityFocusState private var errorFocused: Bool
  @State private var removing: ListParticipant?
  @State private var revoking: PendingInvitation?
  @State private var confirmsLeave = false

  init(model: ShareListModel, center: SharingCenter) {
    _model = State(initialValue: model)
    self.center = center
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.m) {
          Text("«\u{00A0}\(model.listName)\u{00A0}»")
            .font(TicketFont.meta)
            .foregroundStyle(Palette.inkMuted)
          content
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollDismissesKeyboard(.interactively)
      .ticketBackground()
      .navigationTitle(model.isOwner || model.sharing == nil ? "Partager la liste" : "Membres")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
            .accessibilityIdentifier("closeShare")
        }
      }
      .sharingToast(model.toast, revision: model.toastRevision) { model.dismissToast() }
    }
    .presentationDetents([.large])
    .task {
      center.openSheetListId = model.listId
      await model.load()
    }
    .onDisappear {
      if center.openSheetListId == model.listId { center.openSheetListId = nil }
    }
    // Signal `members` ou `invitations` sur cette liste : relecture.
    .onChange(of: center.sharingRevision) { Task { await model.load() } }
    .onChange(of: model.errorRevision) {
      guard let message = model.fieldError else { return }
      AccessibilityNotification.Announcement(message).post()
      emailFocused = true
    }
    .onChange(of: model.didLeave) { _, left in if left { dismiss() } }
    .alert(
      removing.map { "Retirer \($0.name) de la liste ?" } ?? "", isPresented: isPresented($removing),
      presenting: removing
    ) { member in
      Button("Annuler", role: .cancel) { removing = nil }
      Button("Retirer", role: .destructive) { Task { await model.remove(member) } }
        .accessibilityIdentifier("confirmRemoveMember")
    } message: { member in
      Text(
        "\(member.name) ne verra plus «\u{00A0}\(model.listName)\u{00A0}». Vous pourrez l'inviter à nouveau.")
    }
    .alert("Annuler l'invitation ?", isPresented: isPresented($revoking), presenting: revoking) { invitation in
      Button("Garder", role: .cancel) { revoking = nil }
      Button("Annuler l'invitation", role: .destructive) { Task { await model.revoke(invitation) } }
        .accessibilityIdentifier("confirmRevoke")
    } message: { invitation in
      Text("Le lien envoyé à \(invitation.email) ne fonctionnera plus.")
    }
    .alert("Quitter «\u{00A0}\(model.listName)\u{00A0}» ?", isPresented: $confirmsLeave) {
      Button("Annuler", role: .cancel) { confirmsLeave = false }
      Button("Quitter", role: .destructive) { Task { await model.leave() } }
        .accessibilityIdentifier("confirmLeave")
    } message: {
      Text(leaveMessage)
    }
  }

  private var leaveMessage: String {
    let again = model.ownerName.map { "\($0) pourra vous inviter à nouveau." } ?? "Vous pourrez être invité à nouveau."
    return "La liste disparaîtra de vos appareils. \(again)"
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 120)
    case .offline, .failed:
      VStack(alignment: .leading, spacing: Space.s) {
        Text(
          model.state == .offline
            ? "Le partage demande une connexion." : "Le partage n'a pas pu s'ouvrir. Réessayez dans un instant."
        )
        .foregroundStyle(Palette.ink)
        Button {
          Task { await model.load() }
        } label: {
          Text("Réessayer").frame(maxWidth: .infinity)
        }
        .prominentButton()
      }
    case .loaded:
      if model.isOwner {
        ownerContent
      } else {
        memberContent
      }
    }
  }

  // MARK: - Propriétaire

  @ViewBuilder private var ownerContent: some View {
    if model.mailFailure != nil { mailFailureCard }
    inviteForm
    membersSection(manageable: true)
    if !model.invitations.isEmpty { invitationsSection }
    if model.members.count <= 1 && model.invitations.isEmpty {
      Text("Pour l'instant, cette liste n'est qu'à vous.")
        .font(.callout)
        .foregroundStyle(Palette.inkMuted)
    }
  }

  @ViewBuilder private var inviteForm: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Adresse e-mail").font(.subheadline).foregroundStyle(Palette.ink)
      TextField(
        "Adresse e-mail", text: $model.email,
        prompt: Text("prenom@exemple.fr").foregroundStyle(Palette.inkMuted)
      )
      .textContentType(.emailAddress)
      .keyboardType(.emailAddress)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .submitLabel(.send)
      .onSubmit { Task { await model.send() } }
      .focused($emailFocused)
      .foregroundStyle(Palette.ink)
      .padding(.horizontal, Space.s)
      .frame(minHeight: 48)
      .background(Palette.paper, in: RoundedRectangle(cornerRadius: TicketMetrics.radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: TicketMetrics.radius, style: .continuous)
          .strokeBorder(model.fieldError == nil ? Palette.inkMuted : Palette.Sharing.destructive, lineWidth: 1)
      }
      .accessibilityHint(model.fieldError ?? "")
      .accessibilityIdentifier("shareEmailField")
      if let error = model.fieldError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(Palette.Sharing.destructive)
          .accessibilityIdentifier("shareError")
      }
    }
    RoleChooser(selection: $model.role)
    Text(SharingFormat.roleHelp(model.role))
      .font(.callout)
      .foregroundStyle(Palette.inkMuted)
    Button {
      Task { await model.send() }
    } label: {
      HStack(spacing: Space.xs) {
        if model.isSending { ProgressView().tint(Palette.onAccent) }
        Text(model.isSending ? "Envoi…" : "Envoyer l'invitation")
      }
      .frame(maxWidth: .infinity)
    }
    .prominentButton()
    .disabled(!model.canSend)
    .accessibilityIdentifier("sendInvitation")
    Label("La personne invitée verra votre prénom. Les adresses e-mail restent privées.", systemImage: "lock")
      .font(.footnote)
      .foregroundStyle(Palette.inkMuted)
  }

  private var mailFailureCard: some View {
    CautionCard {
      Label {
        Text("L'invitation est prête, mais l'e-mail n'est pas parti.").bold()
      } icon: {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.Sharing.caution)
      }
      Text("Envoyez le lien vous-même\u{00A0}: il est valable 7\u{00A0}jours.")
      Button {
        model.copyFailedMailLink()
      } label: {
        Label("Copier le lien", systemImage: "doc.on.doc").frame(maxWidth: .infinity).touchTarget()
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("copyFailedLink")
      if let link = model.mailFailure?.link {
        ShareLink(item: link) {
          Label("Partager…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).touchTarget()
        }
        .buttonStyle(.bordered)
      }
    }
    .accessibilityIdentifier("mailFailure")
  }

  // MARK: - Membres

  private func membersSection(manageable: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Membres (\(model.members.count))")
      ForEach(model.members) { member in
        memberRow(member, manageable: manageable && !member.isMe && member.role != .owner)
        DottedRule()
      }
    }
  }

  @ViewBuilder private func memberRow(_ member: ListParticipant, manageable: Bool) -> some View {
    let name = member.isMe ? "\(member.name) (vous)" : member.name
    let row = HStack(spacing: Space.s) {
      MemberAvatar(label: member.initial, size: 36, ring: false)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(TicketFont.item.weight(.bold)).foregroundStyle(Palette.ink)
        Text(SharingFormat.roleLabel(member.role)).font(.subheadline).foregroundStyle(Palette.inkMuted)
      }
      Spacer(minLength: Space.xs)
      if model.busy.contains(member.userId) {
        ProgressView()
      } else if manageable {
        Image(systemName: "ellipsis").foregroundStyle(Palette.inkMuted).frame(width: 44, height: 44)
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: 56)
    .contentShape(Rectangle())
    if manageable {
      Menu {
        Section("\(member.name) · \(member.joinedAt.map(SharingFormat.memberSince) ?? "Membre")") {
          Picker(
            "Accès",
            selection: Binding(
              get: { member.role }, set: { role in Task { await model.setRole(member, to: role) } })
          ) {
            Text("Peut modifier").tag(ListRole.editor)
            Text("Lecture seule").tag(ListRole.viewer)
          }
        }
        Button("Retirer de la liste", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
          removing = member
        }
      } label: {
        row
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(member.name), \(SharingFormat.roleLabel(member.role).lowercased()). Gérer")
      .accessibilityIdentifier("member-\(member.name)")
    } else {
      row
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(SharingFormat.roleLabel(member.role).lowercased())")
    }
  }

  @ViewBuilder private var memberContent: some View {
    membersSection(manageable: false)
    Label(
      model.ownerName.map { "Les invitations et les accès sont gérés par \($0)." }
        ?? "Les invitations et les accès sont gérés par la personne qui a partagé la liste.",
      systemImage: "info.circle"
    )
    .font(.footnote)
    .foregroundStyle(Palette.inkMuted)
    Button(role: .destructive) {
      confirmsLeave = true
    } label: {
      Label("Quitter la liste", systemImage: "rectangle.portrait.and.arrow.right")
        .foregroundStyle(Palette.Sharing.destructive)
        .frame(maxWidth: .infinity)
        .touchTarget()
    }
    .padding(.top, Space.l)
    .disabled(model.busy.contains { id in model.members.contains { $0.isMe && $0.userId == id } })
    .accessibilityIdentifier("leaveList")
  }

  // MARK: - Invitations en attente

  private var invitationsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Invitations en attente (\(model.invitations.count))")
      ForEach(model.invitations) { invitation in
        invitationRow(invitation)
        DottedRule()
      }
    }
  }

  private func invitationRow(_ invitation: PendingInvitation) -> some View {
    let expired = invitation.expired || invitation.expiresAt <= .now
    return HStack(spacing: Space.s) {
      VStack(alignment: .leading, spacing: 2) {
        Text(invitation.email).font(.body).foregroundStyle(Palette.ink)
        Text("\(SharingFormat.roleLabel(invitation.role)) · \(SharingFormat.pendingExpiry(invitation, now: .now))")
          .font(.subheadline)
          .foregroundStyle(Palette.inkMuted)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(invitation.email), \(SharingFormat.roleLabel(invitation.role).lowercased()), "
          + SharingFormat.pendingExpiryAccessibility(invitation, now: .now)
      )
      .accessibilityActions {
        Button("Renvoyer") { Task { await model.resend(invitation) } }
        Button("Copier le lien") { Task { await model.copyLink(invitation) } }
        Button("Annuler l'invitation") { revoking = invitation }
      }
      Spacer(minLength: Space.xs)
      if model.busy.contains(invitation.id) {
        ProgressView()
      } else if expired {
        Button("Renvoyer") { Task { await model.resend(invitation) } }
          .buttonStyle(.bordered)
          .frame(minHeight: 44)
          .accessibilityIdentifier("resend-\(invitation.email)")
      } else {
        Menu {
          Button("Renvoyer", systemImage: "arrow.clockwise") { Task { await model.resend(invitation) } }
          Button("Copier le lien", systemImage: "doc.on.doc") { Task { await model.copyLink(invitation) } }
          Button("Annuler l'invitation", systemImage: "xmark.circle", role: .destructive) { revoking = invitation }
        } label: {
          Image(systemName: "ellipsis")
            .foregroundStyle(Palette.ink)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions pour l'invitation de \(invitation.email)")
        .accessibilityIdentifier("invitationActions-\(invitation.email)")
      }
    }
    .frame(minHeight: 56)
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text)
      .font(TicketFont.aisle)
      .tracking(TicketFont.aisleTracking)
      .textCase(.uppercase)
      .foregroundStyle(Palette.inkMuted)
      .padding(.top, Space.m)
      .padding(.bottom, Space.xs)
      .accessibilityAddTraits(.isHeader)
  }

  private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }
}

/// Choix de l'accès : deux segments de 44 pt, empilés aux tailles d'accessibilité, lus comme un groupe de boutons
/// radio (« Accès, Peut modifier, sélectionné »).
struct RoleChooser: View {
  @Binding var selection: ListRole
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("Accès")
        .font(TicketFont.aisle)
        .tracking(TicketFont.aisleTracking)
        .textCase(.uppercase)
        .foregroundStyle(Palette.inkMuted)
        .accessibilityHidden(true)
      let layout =
        typeSize >= .accessibility1 ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
      layout {
        segment(.editor)
        segment(.viewer)
      }
      .padding(4)
      .background(Palette.paperEdge, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Accès")
    }
  }

  private func segment(_ role: ListRole) -> some View {
    let selected = selection == role
    return Button {
      selection = role
    } label: {
      Text(SharingFormat.roleLabel(role))
        .font(.body.weight(.semibold))
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(selected ? Palette.paper : Color.clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .accessibilityHint(SharingFormat.roleHelp(role))
    .accessibilityIdentifier("role-\(role.rawValue)")
  }
}
