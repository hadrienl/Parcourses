import SwiftUI
import UIKit

/// Mode courses, plein écran, habillé en ticket filé (B3, #6) : rayons dans l'ordre du trajet, fil du parcours qui
/// avance d'une perle à chaque coche, dock en verre dans la zone du pouce.
struct ShoppingView: View {
  @State var session: ShoppingSession
  let onClose: () -> Void
  @State private var showsRemaining = false
  @State private var basketIsExpanded = false
  @State private var checkTrigger = 0
  @State private var uncheckTrigger = 0
  /// Rayons qui viennent de remonter en ordre appris (étiquette « ↑ appris »).
  @State private var learnedTags: [String: UUID] = [:]
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 52
  @FocusState private var inputIsFocused: Bool
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast
  /// Ligne sous le focus VoiceOver : elle le garde quand la liste se réordonne.
  @AccessibilityFocusState private var focusedRow: UUID?
  /// Panneau de l'article, ouvert par « Quantité » (#110).
  @State private var editing: ItemEditTarget?
  /// Positions des perles, lues par le trait unique du fil (#115).
  @State private var thread = ThreadTrackModel()
  /// Ligne ouverte par le glisser (« Pas trouvé ») : une seule à la fois.
  @State private var openLane: String?

  var body: some View {
    NavigationStack {
      if let summary = session.summary {
        ShoppingSummaryView(summary: summary, onClose: onClose)
      } else {
        shopping
      }
    }
    .onAppear { setScreenAlwaysOn(session.summary == nil) }
    .onDisappear { setScreenAlwaysOn(false) }
    .onChange(of: scenePhase) { _, phase in
      setScreenAlwaysOn(phase == .active && session.summary == nil)
      if phase == .active { session.foregrounded() }
    }
    .onChange(of: session.summary) { _, summary in
      if summary != nil { setScreenAlwaysOn(false) }
    }
  }

  private func setScreenAlwaysOn(_ value: Bool) {
    UIApplication.shared.isIdleTimerDisabled = value
  }

  private var shopping: some View {
    let sections = session.displayedSections
    let lines = TicketLine.lines(of: sections)
    // Article suivant : le premier non coché dans l'ordre affiché (rayons compris), pas dans `toBuy`.
    let nextId = lines.lazy.compactMap { line -> UUID? in
      if case .item(let row) = line, !row.isChecked { return row.id }
      return nil
    }.first
    // Le fil est parcouru jusqu'à l'article suivant ; tout l'est quand il n'y en a plus.
    let path = ThreadPath(
      ids: lines.map(\.id), next: lines.firstIndex { $0.id == nextId?.uuidString } ?? lines.count)
    return List {
      Section {
        ticketHeader.closesOpenLane(closeLane).ticketRow()
        ForEach(lines) { line in
          switch line {
          case .aisle(let section):
            aisleRow(section, threadId: line.id).threadLineRow()
          case .item(let row):
            itemRow(row, threadId: line.id, next: nextId)
          }
        }
      }
      if !session.notFound.isEmpty {
        Section {
          ForEach(session.notFound) { row in
            notFoundRow(row).ticketRow()
          }
        } header: {
          AisleTitle(title: "Introuvable").accessibilityAddTraits(.isHeader).padding(.top, Space.m)
        }
      }
      if !session.basket.isEmpty {
        Section {
          DisclosureGroup(isExpanded: basketExpansion) {
            ForEach(session.basket) { row in
              basketRow(row)
            }
          } label: {
            Text("Dans le panier (\(session.basket.count))")
              .font(TicketFont.item)
              .foregroundStyle(Palette.ink)
              .rowHeight()
          }
          .tint(Palette.accent)
          .accessibilityIdentifier("basket")
          .ticketRow()
        }
      }
    }
    .listStyle(.plain)
    // Option A′ (#115, §9.2) : ni tri, ni départ, ni ajout ne sont animés. Les lignes changent de place d'un coup ; les
    // bouts du trait, mesurés après la mise en page, ne suivraient pas des cellules animées par UIKit. La coche reste
    // animée sur place (case, perle).
    .threadTrack(thread, path: path)
    .ticketBackground()
    .environment(\.defaultMinListRowHeight, 0)
    // Repère des tests UI (audit d'accessibilité) : la liste du mode courses, distincte de celle de l'écran Liste.
    .accessibilityIdentifier("shoppingList")
    .onChange(of: Self.openableLanes(lines)) { _, ids in
      // Ligne ouverte partie (panier, introuvable, retirée ailleurs) ou cochée : plus rien n'est ouvert.
      if let openLane, !ids.contains(openLane) { self.openLane = nil }
    }
    .onChange(of: session.toBuy.map(\.id)) { old, new in
      listDidChange(from: old, to: new)
      routeDidChange(from: old)
    }
    .onChange(of: session.undo) { _, undo in
      // Une coche se lit déjà dans la valeur de la ligne (« coché ») : seul « introuvable », qui déplace la ligne
      // dans une autre section, est annoncé.
      if let undo, undo.kind == .notFound { ReorderAnnouncement.post(undo.message) }
    }
    .scrollDismissesKeyboard(.interactively)
    .onScrollPhaseChange { _, phase in
      session.setScrolling(phase.isScrolling)
      if phase.isScrolling { closeLane() }
    }
    .onChange(of: inputIsFocused) { _, focused in session.setEditing(focused) }
    .onChange(of: session.input) { session.setEditing(inputIsFocused) }
    .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in session.syncDidChange() }
    // Le ticket porte son propre titre (le magasin, sinon la liste) : pas de barre de navigation au-dessus.
    .toolbar(.hidden, for: .navigationBar)
    .statusBarPaper()
    .sensoryFeedback(.success, trigger: checkTrigger)
    .sensoryFeedback(.impact(weight: .light), trigger: uncheckTrigger)
    .safeAreaInset(edge: .bottom) { dock }
    .opaqueBottomBar()
    // Article disparu (supprimé ailleurs, coché par un autre) ou courses arrêtées : le panneau se ferme.
    .onChange(of: editableIds) { _, ids in
      if let editing, !ids.contains(editing.id) { self.editing = nil }
    }
    .sheet(item: $editing) { target in
      ItemEditSheet(target: target, largeText: dynamicTypeSize.isAccessibilitySize) { edit in
        session.save(edit, for: target.id)
      }
    }
    .sheet(isPresented: remainingIsPresented) {
      RemainingItemsSheet(
        count: session.remainingCount, canCancel: !session.expired,
        onKeep: { session.finish(keepRemaining: true) }, onDrop: { session.finish(keepRemaining: false) },
        onCancel: { showsRemaining = false }
      )
      .presentationDetents([.medium])
      // Fond opaque : le verre de la feuille laisse transparaître la liste et dégrade le contraste.
      .presentationBackground(Palette.paper)
      .interactiveDismissDisabled(session.expired)
    }
    .alert("Erreur", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) { session.errorMessage = nil }
    } message: {
      Text(session.errorMessage ?? "")
    }
    // Liste retirée pendant les courses : feuille non fermable, « Terminer » clôt la visite (#87 §1.5).
    .sheet(isPresented: accessLostIsPresented) {
      AccessLostSheet(end: session.accessEnd ?? .removed) { session.finish(keepRemaining: true) }
        .presentationDetents([.medium])
        .presentationBackground(Palette.paper)
        .interactiveDismissDisabled()
    }
  }

  private var accessLostIsPresented: Binding<Bool> {
    Binding(get: { session.accessLost && session.summary == nil }, set: { _ in })
  }

  /// En ordre appris, un rayon qui remonte après un tri porte « ↑ appris » pendant 3 s : le mouvement s'explique.
  private func routeDidChange(from old: [UUID]) {
    guard !session.groupsByAisle else { return }
    let raised = TicketLine.raisedSections(previous: old, current: session.routeSections)
    guard !raised.isEmpty else { return }
    // Chaque remontée relance les 3 s : une étiquette n'est retirée que par la dernière remontée de son rayon.
    // Sans animation (option A′, #115) : l'étiquette peut changer la hauteur du rayon aux grandes tailles de texte, et
    // des lignes animées quitteraient le trait.
    let token = UUID()
    for id in raised { learnedTags[id] = token }
    Task {
      try? await Task.sleep(for: Motion.learnedTag)
      learnedTags = learnedTags.filter { $0.value != token }
    }
  }

  /// Réordonnancement : annonce discrète du prochain article, focus conservé sur la même ligne (ou sa voisine).
  private func listDidChange(from old: [UUID], to new: [UUID]) {
    if let focused = focusedRow,
      let target = ReorderAnnouncement.focusTarget(previous: old, current: new, focused: focused),
      old.contains(focused)
    {
      focusedRow = target
    }
    guard ReorderAnnouncement.didReorder(previous: old, current: new) else { return }
    let next = session.toBuy.first { !$0.isChecked }
    ReorderAnnouncement.post(ReorderAnnouncement.message(next: next?.accessibilityLabel))
  }

  private var remainingIsPresented: Binding<Bool> {
    Binding(
      get: { session.summary == nil && (showsRemaining || session.expired) },
      set: { showsRemaining = $0 })
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })
  }

  /// En-tête du ticket : le magasin (sinon la liste), ce que l'app sait du trajet, puis le compteur « RESTE 05 ».
  private var ticketHeader: some View {
    VStack(spacing: Space.xs) {
      VStack(spacing: 4) {
        Text(session.storeName ?? session.name)
          .font(TicketFont.title)
          .tracking(TicketFont.titleTracking)
          .textCase(.uppercase)
          .foregroundStyle(Palette.ink)
          .accessibilityLabel(Text(session.storeName ?? session.name))
          .accessibilityAddTraits(.isHeader)
        if session.storeName != nil {
          Text(session.name).font(TicketFont.meta).foregroundStyle(Palette.inkMuted)
        }
        Text(knowledgeText).font(TicketFont.meta).foregroundStyle(Palette.inkMuted)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      DottedRule(dash: [5, 4], lineWidth: 2).padding(.vertical, 4)
      HStack(alignment: .lastTextBaseline) {
        Text("Reste")
          .font(TicketFont.totalCaption)
          .tracking(TicketFont.aisleTracking)
          .textCase(.uppercase)
          .foregroundStyle(Palette.inkMuted)
        Spacer(minLength: Space.s)
        Text(Self.counter(remaining))
          .font(TicketFont.total(size: totalSize))
          .tracking(TicketFont.totalTracking)
          .monospacedDigit()
          .foregroundStyle(Palette.ink)
          .contentTransition(.numericText(countsDown: true))
          .animation(Motion.check(reduced: reduceMotion), value: remaining)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(remainingText)
      .accessibilityIdentifier("shoppingHeader")
      // Le magasin vient d'OpenStreetMap : l'attribution reste là où son nom s'affiche.
      if session.storeName != nil { OSMAttribution() }
    }
    .padding(.top, Space.m)
    .padding(.bottom, Space.xs)
  }

  /// Compteur du ticket, sur deux chiffres au moins.
  static func counter(_ value: Int) -> String {
    TicketCounter.text(value)
  }

  private var remaining: Int {
    session.toBuy.filter { !$0.isChecked }.count
  }

  private var remainingText: String {
    remaining <= 1 ? "\(remaining) restant" : "\(remaining) restants"
  }

  private var knowledgeText: String {
    switch session.knowledge {
    case .noStore: "Sans magasin : ordre par rayon"
    case .unknown: "Vous tracez le premier trajet ici"
    case .learning(let percent): "Trajet en apprentissage (\(percent) %)"
    case .learned(let percent): "Trajet connu à \(percent) %"
    }
  }

  /// Nœud d'un rayon sur le fil : lu comme un en-tête, avec le nombre d'articles à prendre.
  private func aisleRow(_ section: ShoppingSection, threadId: String) -> some View {
    AisleLine(
      aisleId: section.aisleId, title: section.title, accessibilityLabel: section.accessibilityLabel,
      identifier: "aisle-\(section.id)", threadId: threadId
    ) {
      if learnedTags[section.id] != nil {
        // Décoratif : le réordonnancement est déjà annoncé à VoiceOver.
        Text("↑ appris")
          .font(TicketFont.meta)
          .foregroundStyle(Palette.accent)
          .accessibilityHidden(true)
      }
    }
  }

  /// Article sur le fil : la perle reste dans la gouttière ; le couloir (case, libellé, quantité) seul s'enfonce au
  /// toucher, glisse vers « Pas trouvé » et se soulève sous le menu (#115).
  private func itemRow(_ row: ShoppingRow, threadId: String, next: UUID?) -> some View {
    let isNext = row.id == next
    let bead: BeadState = row.isChecked ? .done : (isNext ? .next : .idle)
    // Glisser complet permis, comme le balayage système qu'il remplace. Lignes à prendre seulement.
    let notFound =
      row.isChecked
      ? nil
      : LaneAction(
        title: "Pas trouvé", systemImage: "questionmark.circle", tint: Palette.notFoundSwipe, allowsFullSwipe: true
      ) { session.markNotFound(row) }
    return ThreadRow(id: threadId, onGutterTap: { tapped(row) }) {
      Bead(state: bead)
    } lane: {
      RowLane(id: threadId, openId: $openLane, action: notFound) {
        Button {
          tapped(row)
        } label: {
          // L'état se lit sans couleur : case pleine avec coche, et texte barré.
          ItemLine(
            label: row.label, quantity: row.quantity, isChecked: row.isChecked, isNext: isNext,
            authorMark: row.authorMark
          )
          // Fond dans le bouton : l'aperçu soulevé du menu le garde. Surlignage de l'article ajouté dans le couloir
          // seul (D3), la gouttière reste papier.
          .background {
            ZStack {
              Palette.paper
              if session.highlightedItemId == row.id { highlight }
            }
          }
        }
        .buttonStyle(LanePressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.isChecked ? "coché" : "non coché")
        .accessibilityHint(row.isChecked ? "Décoche l'article" : "Coche l'article")
        .accessibilityAddTraits(.isToggle)
        .accessibilityFocused($focusedRow, equals: row.id)
        // Chaque action n'est proposée que là où elle a un sens.
        .accessibilityActions {
          if row.isChecked {
            Button("Décocher") { session.toggle(row) }
          } else {
            Button("Pas trouvé") { session.markNotFound(row) }
            Button("Modifier la quantité") { edit(row) }
          }
        }
        // Aperçu soulevé : le couloir seul (D4). Le système le place à 16 pt du bord d'écran et la carte cache la perle
        // de sa ligne le temps du menu ; le fil, lui, ne bouge pas sous le voile.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: TicketMetrics.radius, style: .continuous))
        .contextMenu {
          // Lignes à prendre seulement, comme Android.
          if !row.isChecked {
            Button("Pas trouvé", systemImage: "questionmark.circle") { session.markNotFound(row) }
            Button("Quantité", systemImage: "number") { edit(row) }
          }
        }
      }
    }
    .threadLineRow()
  }

  /// Toucher une ligne coche ou décoche ; quand une ligne est ouverte par le glisser, il la referme seulement. Avec
  /// VoiceOver, le double-toucher referme et agit : l'utilisateur ne voit pas forcément la ligne ouverte.
  private func tapped(_ row: ShoppingRow) {
    if openLane != nil {
      closeLane()
      guard voiceOverEnabled else { return }
    }
    if row.isChecked { uncheckTrigger += 1 } else { checkTrigger += 1 }
    session.toggle(row)
  }

  /// Lignes qui peuvent être ouvertes par le glisser : les articles à prendre.
  private static func openableLanes(_ lines: [TicketLine]) -> Set<String> {
    Set(
      lines.compactMap { line in
        if case .item(let row) = line, !row.isChecked { return line.id }
        return nil
      })
  }

  /// Panier replié ou déplié sans animation (option A′, #115) : en bas de la liste, le replier ramène le contenu, et
  /// les lignes du fil glisseraient sous un trait qui, lui, ne suit que leur place finale.
  private var basketExpansion: Binding<Bool> {
    Binding(
      get: { basketIsExpanded },
      set: { expanded in
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { basketIsExpanded = expanded }
      })
  }

  private func closeLane() {
    guard openLane != nil else { return }
    withAnimation(LaneMotion.settle(reduced: reduceMotion)) { openLane = nil }
  }

  /// Articles que le panneau peut modifier : ceux à prendre, tant que les courses continuent.
  private var editableIds: Set<UUID> {
    guard session.accessEnd == nil, !session.expired else { return [] }
    return Set(session.toBuy.filter { !$0.isChecked }.map(\.id))
  }

  /// Même panneau que l'écran Liste (#110).
  private func edit(_ row: ShoppingRow) {
    editing = ItemEditTarget(id: row.id, label: row.label, quantity: row.quantity)
  }

  /// Article tout juste ajouté : repéré par un fond d'accent léger.
  private var highlight: Color {
    Palette.accent.opacity(contrast == .increased ? 0.3 : 0.15)
  }

  /// Article du panier : hors du fil, aligné sur les articles du ticket.
  private func basketRow(_ row: ShoppingRow) -> some View {
    Button {
      uncheckTrigger += 1
      session.toggle(row)
    } label: {
      ItemLine(label: row.label, quantity: row.quantity, isChecked: row.isChecked, authorMark: row.authorMark)
    }
    .buttonStyle(.plain)
    .ticketRow()
    .accessibilityElement(children: .combine)
    // « Lait entier, 2, dans le panier, par Léa » : l'article pris par un autre membre (#87).
    .accessibilityLabel(
      row.authorName.map { "\(row.accessibilityLabel), dans le panier, par \($0)" } ?? row.accessibilityLabel
    )
    .accessibilityValue(row.isChecked ? "coché" : "non coché")
    .accessibilityHint(row.isChecked ? "Décoche l'article" : "Coche l'article")
    .accessibilityAddTraits(.isToggle)
    .accessibilityFocused($focusedRow, equals: row.id)
    .accessibilityActions {
      if row.isChecked { Button("Décocher") { session.toggle(row) } }
    }
  }

  private func notFoundRow(_ row: ShoppingRow) -> some View {
    Button {
      session.restore(row)
    } label: {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Space.s) {
          Image(systemName: "questionmark.circle")
          Text(row.label).font(TicketFont.item).strikethrough()
          Spacer()
          Text("Remettre").font(TicketFont.quantity.weight(.bold)).foregroundStyle(Palette.accent)
        }
        VStack(alignment: .leading) {
          Label(row.label, systemImage: "questionmark.circle").font(TicketFont.item)
          Text("Remettre").font(TicketFont.quantity.weight(.bold)).foregroundStyle(Palette.accent)
        }
      }
      .foregroundStyle(Palette.inkMuted)
      .rowHeight()
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue("introuvable")
    .accessibilityHint("Remet l'article dans la liste")
  }

  /// Dock flottant en verre, dans la zone du pouce : bannière « Annuler » au-dessus, saisie et « Terminer ».
  private var dock: some View {
    VStack(spacing: Space.xs) {
      if let undo = session.undo {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Space.s) {
            Text(undo.message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("undoMessage")
            undoButton
          }
          VStack(alignment: .leading, spacing: 0) {
            Text(undo.message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("undoMessage")
            undoButton
          }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs / 2)
        .ticketBanner()
        .transition(.opacity)
      }
      if session.isEverythingChecked {
        Text("Tout est coché !")
          .font(TicketFont.item.weight(.bold))
          .foregroundStyle(Palette.ink)
          .padding(.horizontal, Space.m)
          .frame(minHeight: 44)
          .ticketBanner()
          .accessibilityIdentifier("allChecked")
      }
      // Aux grandes tailles de texte, « Terminer » passe sous le champ.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Space.xs) {
          entryField
          finishButton
        }
        VStack(spacing: Space.xs) {
          entryField
          finishButton
        }
      }
      .floatingDock()
    }
    .closesOpenLane(closeLane)
    .animation(Motion.fade, value: session.undo)
  }

  private var undoButton: some View {
    Button {
      session.performUndo()
    } label: {
      // Jamais tronqué : si la place manque, `ViewThatFits` passe le bouton sous le message.
      // Pastille pleine à l'accent, comme « Terminer » : le libellé à l'accent sur le papier mesure 7,7:1 sur capture,
      // mais l'audit de contraste d'iOS 26 le rejette en clair. La pastille garde une cible de 44 pt.
      Text("Annuler")
        .fontWeight(.bold)
        .foregroundStyle(Palette.onAccent)
        .fixedSize()
        .padding(.horizontal, Space.s + 2)
        .frame(minHeight: 34)
        .background(Palette.accent, in: Capsule())
        .touchTarget()
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("undo")
  }

  private var entryField: some View {
    TextField(EntryPrompt.shortPlaceholder, text: $session.input, prompt: EntryPrompt.shortText)
      .entryField(focus: $inputIsFocused)
      .submitLabel(.done)
      .accessibilityIdentifier("shoppingEntry")
      .onSubmit(submit)
  }

  private var finishButton: some View {
    Button(action: finishTapped) {
      // Jamais tronqué : si la place manque, `ViewThatFits` passe le bouton sous le champ.
      Text("Terminer").fixedSize()
    }
    .prominentButton(size: .dock)
    // Le mode courses ne s'affiche qu'une fois prêt ; garde-fou si cela change (#54).
    .disabled(!session.isPrepared)
    .accessibilityIdentifier("finish")
  }

  private func submit() {
    Task {
      await session.submit()
      inputIsFocused = true
    }
  }

  private func finishTapped() {
    if session.remainingCount > 0 {
      showsRemaining = true
    } else {
      session.finish(keepRemaining: true)
    }
  }
}

/// « 2 articles non cochés : les garder pour la prochaine fois ? » (#6)
/// Accès retiré ou passé en lecture seule pendant les courses (maquette, écran 6) : le titre prend le focus,
/// « Terminer » clôt la visite.
private struct AccessLostSheet: View {
  let end: ShoppingSession.AccessEnd
  let onFinish: () -> Void
  @AccessibilityFocusState private var titleFocused: Bool

  private var title: String {
    switch end {
    case .removed: "Vous n'avez plus accès à cette liste"
    case .readOnly(let ownerName): SharingFormat.downgradedTitle(ownerName: ownerName)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Space.m) {
      Text(title)
        .font(.title2.weight(.bold))
        .foregroundStyle(Palette.ink)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      Text("Les courses s'arrêtent ici. Vos coches comptent quand même pour le trajet du magasin.")
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: onFinish) {
        Text("Terminer").frame(maxWidth: .infinity)
      }
      .prominentButton()
      .accessibilityIdentifier("finishAfterAccessLost")
    }
    .padding(Space.l)
    .onAppear { titleFocused = true }
    .accessibilityIdentifier("accessLost")
  }
}

private struct RemainingItemsSheet: View {
  let count: Int
  let canCancel: Bool
  let onKeep: () -> Void
  let onDrop: () -> Void
  let onCancel: () -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Text(count == 1 ? "1 article non coché" : "\(count) articles non cochés")
          .font(TicketFont.title)
          .foregroundStyle(Palette.ink)
        Text("Les garder pour la prochaine fois ?")
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(Palette.ink)
        Button("Les garder", action: onKeep)
          .prominentButton()
          .accessibilityIdentifier("keepRemaining")
        Button(role: .destructive, action: onDrop) {
          // Rouge plus soutenu que le rouge système (≈ 3,6:1 sur blanc) : 5,4:1 en clair, 6:1 en sombre.
          Text("Les retirer de la liste").foregroundStyle(Color("DestructiveText")).touchTarget()
        }
        if canCancel {
          Button(action: onCancel) {
            Text("Continuer mes courses").fontWeight(.semibold).foregroundStyle(Palette.accent).touchTarget()
          }
        }
      }
      .multilineTextAlignment(.center)
      .padding()
    }
    .scrollBounceBehavior(.basedOnSize)
    .ticketBackground()
  }
}

/// Fin des courses : « 12 articles en 18 min » et la contribution.
struct ShoppingSummaryView: View {
  let summary: ShoppingSummary
  let onClose: () -> Void
  @State private var appeared = false
  /// Grand chiffre du résumé : 40 pt à la taille par défaut, mis à l'échelle comme le grand titre.
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 40

  var body: some View {
    // Centré quand il tient dans l'écran, ouvert en haut quand il déborde (grandes tailles de texte).
    GeometryReader { proxy in
      ScrollView {
        summaryContent
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .safeAreaInset(edge: .bottom) {
      Button("Retour aux listes", action: onClose)
        .prominentButton()
        .accessibilityIdentifier("closeSummary")
        .padding()
    }
    .background(Palette.paper.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .statusBarPaper()
    .sensoryFeedback(.success, trigger: appeared)
    .onAppear { appeared = true }
  }

  private var summaryContent: some View {
    VStack(spacing: 16) {
      Text(summary.checkedCount <= 1 ? "\(summary.checkedCount) article" : "\(summary.checkedCount) articles")
        .font(TicketFont.total(size: totalSize))
        .foregroundStyle(Palette.ink)
      Text("en \(summary.minutes) min").font(TicketFont.title).foregroundStyle(Palette.ink)
      DottedRule(dash: [5, 4], lineWidth: 2).frame(maxWidth: 240).padding(.vertical, Space.xs)
      if let contribution {
        Text(contribution)
          .font(.system(.body, design: .monospaced))
          .multilineTextAlignment(.center)
          .foregroundStyle(Palette.inkMuted)
          .accessibilityIdentifier("contribution")
      }
      if summary.storeName != nil { OSMAttribution() }
    }
    .multilineTextAlignment(.center)
    .padding()
  }

  private var contribution: String? {
    guard let store = summary.storeName else { return nil }
    switch summary.knowledge {
    case .noStore: return nil
    case .unknown: return "Vous avez tracé le premier trajet à \(store), merci."
    case .learning(let percent), .learned(let percent): return "\(store) est cartographié à \(percent) %, merci."
    }
  }
}
