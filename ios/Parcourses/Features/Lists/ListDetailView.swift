import SwiftUI
import TipKit

/// Une ligne du ticket de l'écran Liste : le nœud d'un rayon, ou un article.
private enum ListLine: Identifiable {
  case aisle(ItemSection)
  case item(ItemRow)

  var id: String {
    switch self {
    case .aisle(let section): "aisle:\(section.id)"
    case .item(let row): row.id.uuidString
    }
  }
}

/// Écran Liste : ticket groupé par rayon sur le fil (encore à parcourir), saisie rapide dans un dock en verre en bas.
struct ListDetailView: View {
  @State private var model: ListDetailModel
  @FocusState private var inputIsFocused: Bool
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 52
  private let onShop: (UUID) -> Void
  /// Absents sans serveur : ni partage ni membres.
  @Environment(SharingCenter.self) private var sharing: SharingCenter?
  @Environment(AccountSession.self) private var account: AccountSession?
  @Environment(\.dismiss) private var dismiss
  @State private var shareModel: ShareListModel?
  @State private var signIn: AccountLink?
  /// Lecteur : la capsule « Lecture seule… » ne s'affiche qu'une fois par ouverture.
  @State private var readOnlyNoticeShown = false
  @State private var toast: String?
  @State private var toastRevision = 0
  @AccessibilityFocusState private var badgeFocused: Bool
  /// Panneau de l'article ouvert par un appui long (#110).
  @State private var editing: ItemEditTarget?
  /// Ligne sous le doigt pendant l'appui long : elle s'enfonce légèrement.
  @State private var pressedRow: UUID?
  @State private var editTrigger = 0
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private let quantityTip = QuantityTip()

  init(
    model: ListDetailModel,
    onShop: @escaping (UUID) -> Void = { _ in
      // Sans navigation : aperçus et tests.
    }
  ) {
    _model = State(initialValue: model)
    self.onShop = onShop
  }

  var body: some View {
    let lines = model.sections.flatMap { section in
      [ListLine.aisle(section)] + section.items.map(ListLine.item)
    }
    // Écran de préparation : le fil est tracé, rien n'est encore parcouru.
    let places = ThreadPlace.places(count: lines.count, reached: nil, progress: false)
    List {
      if !model.isMissing { titleLine.ticketRow() }
      if let change = accessChange { accessBanner(change).ticketRow() }
      if isOffline { offlineBanner.ticketRow() }
      if model.access.isReadOnly {
        SharingBadge(kind: .readOnly)
          .padding(.top, Space.xs)
          .accessibilityFocused($badgeFocused)
          .ticketRow()
      }
      if !model.isEmpty {
        header.ticketRow()
        lastChangeLine.ticketRow()
        if model.access.capabilities.canEditItems {
          TipView(quantityTip, arrowEdge: nil)
            .tipBackground(Palette.paperEdge)
            .padding(.top, Space.xs)
            .accessibilityIdentifier("quantityTip")
            .ticketRow()
        }
      }
      ForEach(Array(zip(lines, places)), id: \.0.id) { line, place in
        switch line {
        case .aisle(let section):
          aisleRow(section, place: place).ticketRow()
        case .item(let row):
          itemRow(row, place: place)
        }
      }
    }
    .listStyle(.plain)
    .ticketBackground()
    .environment(\.defaultMinListRowHeight, 0)
    // Repère des tests UI (audit d'accessibilité) : la liste de l'écran Liste.
    .accessibilityIdentifier("itemList")
    .scrollDismissesKeyboard(.interactively)
    .overlay {
      if model.wasRemoved {
        removedState
      } else if model.isMissing {
        EmptyState(
          title: "Liste introuvable", systemImage: "questionmark.folder", description: "Cette liste a été supprimée.")
      } else if model.isLoaded && model.isEmpty {
        EmptyState(
          title: "Liste vide", systemImage: "basket",
          description: "Ajoutez un article, par exemple « 2 laits demi-écrémé ».")
      }
    }
    // Titre dans le ticket (`titleLine`), pas dans la barre : elle porte les pastilles et le chariot, un titre y serait
    // tronqué (maquette sharing-v1, décision « Titre de la liste sur iOS »).
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(model.wasRemoved)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if !model.isMissing {
          membersButton
          if model.access.capabilities.canShop {
            Button("Faire mes courses", systemImage: "cart") { onShop(model.listId) }
              .labelStyle(.titleAndIcon)
              .disabled(model.isEmpty)
              .accessibilityIdentifier("startShopping")
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if !model.isMissing {
        if model.access.capabilities.canEditItems { dock } else { readOnlyNote }
      }
    }
    .opaqueBottomBar()
    .sharingToast(toast, revision: toastRevision) { toast = nil }
    .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in model.load() }
    .task {
      model.load()
      inputIsFocused = model.isEmpty && !model.isMissing && model.access.capabilities.canEditItems
    }
    // « Quitter la liste » : retour à Mes listes (la feuille se ferme d'elle-même).
    .onChange(of: model.didLeave) { _, left in if left { dismiss() } }
    .onChange(of: accessChange) { _, change in
      // Accès changé : annonce de la bannière, puis focus sur le badge « Lecture seule » (maquette, écran 1).
      guard let change else { return }
      model.load()
      AccessibilityNotification.Announcement(accessMessage(change)).post()
      if model.access.isReadOnly { badgeFocused = true }
    }
    // Article disparu (supprimé ailleurs, liste retirée) ou édition plus permise (passé lecteur) : le panneau se ferme,
    // plutôt que d'échouer ou de perdre la saisie en silence à l'enregistrement.
    .onChange(of: editableIds) { _, ids in
      if let editing, !ids.contains(editing.id) { self.editing = nil }
    }
    .sheet(item: $editing) { target in
      ItemEditSheet(target: target, largeText: dynamicTypeSize.isAccessibilitySize) { edit in
        model.save(edit, for: target.id)
      }
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: editTrigger)
    .sheet(item: $shareModel) { share in
      if let sharing { ShareListSheet(model: share, center: sharing) }
    }
    .sheet(item: $signIn) { link in
      AccountSignInView(link: link, context: .share) {
        Task {
          await account?.linkDidFinish()
          await sharing?.foreground()
          // Adresse liée : la feuille « Partager » s'ouvre ensuite.
          if sharing?.isEmailAccount == true { openShare() }
        }
      }
    }
    .alert("Erreur", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  /// Nom de la liste en tête du ticket, en mono majuscules comme le magasin du mode courses ; passe sur plusieurs
  /// lignes plutôt que d'être tronqué. Lu comme l'en-tête de l'écran, avec la casse saisie.
  private var titleLine: some View {
    Text(model.name)
      .font(TicketFont.title)
      .tracking(TicketFont.titleTracking)
      .textCase(.uppercase)
      .foregroundStyle(Palette.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, Space.xs)
      .accessibilityLabel(Text(model.name))
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("listTitle")
  }

  /// Compteur du ticket : « ARTICLES 06 ».
  private var header: some View {
    let count = model.sections.reduce(0) { $0 + $1.items.count }
    return HStack(alignment: .lastTextBaseline) {
      Text("Articles")
        .font(TicketFont.totalCaption)
        .tracking(TicketFont.aisleTracking)
        .textCase(.uppercase)
        .foregroundStyle(Palette.inkMuted)
      Spacer(minLength: Space.s)
      Text(ShoppingView.counter(count))
        .font(TicketFont.total(size: totalSize))
        .tracking(TicketFont.totalTracking)
        .monospacedDigit()
        .foregroundStyle(Palette.ink)
    }
    .padding(.top, Space.xs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(count <= 1 ? "\(count) article" : "\(count) articles")
  }

  /// « Modifiée par Léa · il y a 2 min », sous le compteur ; masquée si la dernière modification est la mienne.
  @ViewBuilder private var lastChangeLine: some View {
    if let change = model.lastChange {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        Text(SharingFormat.modifiedBy(change.name, at: change.date, now: context.date))
          .font(TicketFont.meta)
          .foregroundStyle(Palette.inkMuted)
          // Passe à la ligne aux grandes tailles au lieu d'être rognée.
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel(SharingFormat.modifiedByAccessibility(change.name, at: change.date, now: context.date))
      }
      .accessibilityIdentifier("lastChange")
    }
  }

  /// Nœud d'un rayon sur le fil, lu comme un en-tête.
  private func aisleRow(_ section: ItemSection, place: ThreadPlace) -> some View {
    AisleLine(
      aisleId: section.categoryId, title: section.title, identifier: "aisle-\(section.categoryId)", place: place)
  }

  @ViewBuilder private func itemRow(_ row: ItemRow, place: ThreadPlace) -> some View {
    if model.access.isReadOnly {
      readOnlyRow(row, place: place)
    } else {
      editableRow(row, place: place)
    }
  }

  /// `pressed` : appui en cours (#110). Seuls la case et le texte de l'article s'enfoncent (`ItemLine`) ; le fil et sa
  /// perle, dessinés par `ThreadRow` dans la gouttière, et la marque d'auteur restent immobiles.
  private func line(_ row: ItemRow, place: ThreadPlace, readOnly: Bool, pressed: Bool = false) -> some View {
    ThreadRow(place: place) {
      // Préparation : rien n'est parcouru, la case seule porte l'état coché.
      Bead(state: .idle)
    } content: {
      // L'état se lit sans couleur : case pleine avec coche, et texte barré.
      ItemLine(
        label: row.label, quantity: row.quantity, isChecked: row.isChecked, authorMark: row.authorMark,
        readOnly: readOnly, pressed: pressed)
    }
  }

  /// Toucher coche, glisser supprime, maintenir ouvre le panneau de l'article (#110). Pendant l'appui, la case et le
  /// texte s'enfoncent (pas le fil) ; au déclenchement, une vibration. Pas de `Button` : son action partirait aussi au
  /// relâcher de l'appui long.
  private func editableRow(_ row: ItemRow, place: ThreadPlace) -> some View {
    let pressed = pressedRow == row.id
    return line(row, place: place, readOnly: false, pressed: pressed)
      .contentShape(Rectangle())
      .onTapGesture { model.toggle(row) }
      .onLongPressGesture(minimumDuration: 0.5) {
        edit(row)
      } onPressingChanged: { pressing in
        if pressing {
          pressedRow = row.id
        } else if pressedRow == row.id {
          pressedRow = nil
        }
      }
      .ticketRow()
      .accessibilityElement(children: .combine)
      .accessibilityLabel(row.accessibilityLabel)
      .accessibilityValue(row.accessibilityState)
      .accessibilityHint(row.isChecked ? "Décoche l'article" : "Coche l'article")
      .accessibilityAddTraits([.isButton, .isToggle])
      .accessibilityAction { model.toggle(row) }
      .accessibilityActions {
        if row.isChecked { Button("Décocher") { model.toggle(row) } }
        Button("Modifier la quantité") { edit(row) }
      }
      .sensoryFeedback(.success, trigger: row.isChecked) { _, checked in checked }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button("Supprimer", systemImage: "trash", role: .destructive) { model.delete(row) }
      }
  }

  /// Articles que le panneau peut modifier.
  private var editableIds: Set<UUID> {
    guard model.access.capabilities.canEditItems, !model.isMissing, !model.wasRemoved else { return [] }
    return Set(model.sections.flatMap(\.items).map(\.id))
  }

  /// Ouvre le panneau de l'article ; l'astuce a servi, elle ne revient plus.
  private func edit(_ row: ItemRow) {
    guard let target = model.editTarget(for: row) else { return }
    quantityTip.invalidate(reason: .actionPerformed)
    editTrigger += 1
    editing = target
  }

  /// Lecteur : ni case ni coche ; toucher un article le rappelle une fois (maquette, écran 7).
  private func readOnlyRow(_ row: ItemRow, place: ThreadPlace) -> some View {
    line(row, place: place, readOnly: true)
      .contentShape(Rectangle())
      .onTapGesture {
        guard !readOnlyNoticeShown else { return }
        readOnlyNoticeShown = true
        show("Lecture seule\u{00A0}: cette liste ne se modifie pas ici.")
      }
      .ticketRow()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(row.accessibilityLabel)
      .accessibilityValue(row.isChecked ? "dans le panier" : "")
  }

  // MARK: - Partage (#87, lot 87.4)

  /// Pastilles des autres membres (liste partagée), « Partager la liste » (propriétaire d'une liste à soi seul).
  @ViewBuilder private var membersButton: some View {
    if let sharing, sharing.isAvailable {
      if model.access.isShared {
        Button(action: shareTapped) {
          BarAvatarStack(labels: model.access.pillLabels)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.access.membersButtonLabel)
        // Visionneuse de grand contenu (appui long), comme les boutons système de la barre.
        .accessibilityShowsLargeContentViewer {
          Label(model.access.membersButtonLabel, systemImage: "person.2")
        }
        .accessibilityIdentifier("listMembers")
      } else if model.access.capabilities.canShare {
        Button("Partager la liste", systemImage: "person.badge.plus", action: shareTapped)
          .accessibilityIdentifier("shareList")
      }
    }
  }

  private func shareTapped() {
    guard let sharing else { return }
    // Compte anonyme : lier une adresse d'abord (§1.1), puis la feuille s'ouvre.
    if !sharing.isEmailAccount, model.access.capabilities.canShare, let account {
      signIn = account.makeLink()
      return
    }
    openShare()
  }

  private func openShare() {
    guard let sharing else { return }
    shareModel = sharing.makeShareModel(listId: model.listId, listName: model.name)
  }

  private var accessChange: SharingAccessChange? {
    guard let change = sharing?.accessChanges[model.listId], change.kind != .removed else { return nil }
    return change
  }

  private func accessMessage(_ change: SharingAccessChange) -> String {
    switch change.kind {
    case .downgraded(let dropped): SharingFormat.downgraded(ownerName: change.ownerName, dropped: dropped)
    case .upgraded: SharingFormat.upgraded(ownerName: change.ownerName)
    case .removed: SharingFormat.removedTitle(change.listName)
    }
  }

  private func accessBanner(_ change: SharingAccessChange) -> some View {
    CautionCard {
      Label {
        Text(accessMessage(change)).fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.Sharing.caution)
      }
      HStack {
        Spacer()
        Button("Compris") { sharing?.acknowledgeChange(listId: model.listId) }
          .font(.body.weight(.semibold))
          .frame(minHeight: 44)
          .accessibilityIdentifier("acknowledgeAccess")
      }
    }
    .padding(.top, Space.xs)
    .accessibilityIdentifier("accessBanner")
  }

  private var isOffline: Bool {
    model.access.isShared && sharing?.isOnline == false
  }

  private var offlineBanner: some View {
    Label("Hors ligne. Vos modifications partiront au retour du réseau.", systemImage: "wifi.slash")
      .font(.callout)
      .foregroundStyle(Palette.ink)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .padding(.horizontal, Space.s)
      .background(Palette.paperEdge, in: RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous))
      .padding(.top, Space.xs)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Hors ligne. Vos modifications partiront au retour du réseau.")
      .accessibilityIdentifier("offlineBanner")
  }

  /// Note du bas d'un lecteur : un texte, pas un bouton désactivé.
  private var readOnlyNote: some View {
    Label(SharingFormat.askOwner(model.access.ownerName), systemImage: "lock")
      .font(.callout)
      .foregroundStyle(Palette.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      .padding(.horizontal, Space.m)
      .floatingDock()
      // Un seul élément, le texte seul : sinon l'icône et le texte portent chacun l'identifiant.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(SharingFormat.askOwner(model.access.ownerName))
      .accessibilityIdentifier("readOnlyNote")
  }

  /// Liste retirée pendant qu'elle était ouverte (maquette, écran 1, état « retirée »).
  private var removedState: some View {
    VStack(spacing: Space.m) {
      Image(systemName: "rectangle.portrait.and.arrow.right")
        .font(.largeTitle)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text(SharingFormat.removedTitle(model.name))
        .font(.title2.weight(.bold))
        .foregroundStyle(Palette.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text("Elle a été retirée de cet appareil.")
        .foregroundStyle(Palette.inkMuted)
        .multilineTextAlignment(.center)
      Button {
        // Déjà annoncée ici : Mes listes ne la répète pas.
        if let removal = sharing?.removedLists.first(where: { $0.listId == model.listId }) {
          sharing?.acknowledgeRemoval(removal)
        }
        dismiss()
      } label: {
        Text("Retour à mes listes").frame(maxWidth: .infinity)
      }
      .prominentButton()
      .accessibilityIdentifier("backToLists")
    }
    .padding(Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
  }

  private func show(_ message: String) {
    toast = message
    toastRevision += 1
  }

  private var dock: some View {
    VStack(spacing: 8) {
      let suggestions = model.suggestions
      if !suggestions.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(suggestions) { suggestion in
              Button {
                donate(model.add(suggestion))
              } label: {
                Text(suggestion.label)
                  .font(.system(.body, design: .monospaced).weight(.medium))
                  .foregroundStyle(Palette.ink)
                  .padding(.horizontal, Space.m)
                  .touchTarget()
                  .background(Palette.paper, in: Capsule())
                  .overlay { Capsule().strokeBorder(Palette.paperEdge) }
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Ajouter \(suggestion.label)")
              .accessibilityIdentifier("suggestion")
            }
          }
        }
      }
      HStack {
        TextField(EntryPrompt.placeholder, text: $model.input, prompt: EntryPrompt.text)
          .entryField(focus: $inputIsFocused)
          .submitLabel(.done)
          .accessibilityIdentifier("quickEntry")
          .onSubmit(submit)
        Button(action: submit) {
          Label("Ajouter", systemImage: "plus")
            .labelStyle(.iconOnly)
            .font(.title3.weight(.bold))
            .frame(minWidth: 44)
            .touchTarget()
        }
        .prominentButton(size: .dock, compact: true)
        .disabled(model.input.allSatisfy(\.isWhitespace))
        .accessibilityIdentifier("addItem")
      }
    }
    .floatingDock()
  }

  /// Le clavier reste ouvert : on enchaîne les articles.
  private func submit() {
    donate(model.submit())
    inputIsFocused = true
  }

  /// Un article ajouté rend l'astuce de l'appui long éligible (TipKit).
  private func donate(_ outcome: EntryOutcome?) {
    guard case .added = outcome else { return }
    Task { await QuantityTip.itemAdded.donate() }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }
}
