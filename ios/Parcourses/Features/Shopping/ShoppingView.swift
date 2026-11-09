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
  @Environment(\.colorSchemeContrast) private var contrast
  /// Ligne sous le focus VoiceOver : elle le garde quand la liste se réordonne.
  @AccessibilityFocusState private var focusedRow: UUID?

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
    let places = ThreadPlace.places(
      count: lines.count, reached: lines.firstIndex { $0.id == nextId?.uuidString }, progress: true)
    return List {
      Section {
        ticketHeader.ticketRow()
        ForEach(Array(zip(lines, places)), id: \.0.id) { line, place in
          switch line {
          case .aisle(let section):
            aisleRow(section, place: place).ticketRow()
          case .item(let row):
            itemRow(row, place: place, next: nextId)
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
          DisclosureGroup(isExpanded: $basketIsExpanded) {
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
    .ticketBackground()
    .environment(\.defaultMinListRowHeight, 0)
    // Repère des tests UI (audit d'accessibilité) : la liste du mode courses, distincte de celle de l'écran Liste.
    .accessibilityIdentifier("shoppingList")
    .animation(Motion.reorder(reduced: reduceMotion), value: lines.map(\.id))
    .animation(Motion.reorder(reduced: reduceMotion), value: session.basket.map(\.id))
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
    .onScrollPhaseChange { _, phase in session.setScrolling(phase.isScrolling) }
    .onChange(of: inputIsFocused) { _, focused in session.setEditing(focused) }
    .onChange(of: session.input) { session.setEditing(inputIsFocused) }
    .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in session.syncDidChange() }
    // Le ticket porte son propre titre (le magasin, sinon la liste) : pas de barre de navigation au-dessus.
    .toolbar(.hidden, for: .navigationBar)
    .sensoryFeedback(.success, trigger: checkTrigger)
    .sensoryFeedback(.impact(weight: .light), trigger: uncheckTrigger)
    .safeAreaInset(edge: .bottom) { dock }
    .opaqueBottomBar()
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
  }

  /// En ordre appris, un rayon qui remonte après un tri porte « ↑ appris » pendant 3 s : le mouvement s'explique.
  private func routeDidChange(from old: [UUID]) {
    guard !session.groupsByAisle else { return }
    let raised = TicketLine.raisedSections(previous: old, current: session.routeSections)
    guard !raised.isEmpty else { return }
    // Chaque remontée relance les 3 s : une étiquette n'est retirée que par la dernière remontée de son rayon.
    let token = UUID()
    withAnimation(Motion.fade) { for id in raised { learnedTags[id] = token } }
    Task {
      try? await Task.sleep(for: Motion.learnedTag)
      withAnimation(Motion.fade) { learnedTags = learnedTags.filter { $0.value != token } }
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
    value < 10 ? "0\(max(0, value))" : "\(value)"
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
  private func aisleRow(_ section: ShoppingSection, place: ThreadPlace) -> some View {
    AisleLine(
      aisleId: section.aisleId, title: section.title, accessibilityLabel: section.accessibilityLabel,
      identifier: "aisle-\(section.id)", place: place
    ) {
      if learnedTags[section.id] != nil {
        // Décoratif : le réordonnancement est déjà annoncé à VoiceOver.
        Text("↑ appris")
          .font(TicketFont.meta)
          .foregroundStyle(Palette.accent)
          .accessibilityHidden(true)
          .transition(.opacity)
      }
    }
  }

  private func itemRow(_ row: ShoppingRow, place: ThreadPlace, next: UUID?) -> some View {
    let isNext = row.id == next
    let bead: BeadState = row.isChecked ? .done : (isNext ? .next : .idle)
    return Button {
      if row.isChecked { uncheckTrigger += 1 } else { checkTrigger += 1 }
      session.toggle(row)
    } label: {
      ThreadRow(place: place) {
        Bead(state: bead)
      } content: {
        // L'état se lit sans couleur : case pleine avec coche, et texte barré.
        ItemLine(label: row.label, quantity: row.quantity, isChecked: row.isChecked, isNext: isNext)
      }
    }
    .buttonStyle(.plain)
    .ticketRow(background: session.highlightedItemId == row.id ? highlight : Palette.paper)
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
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if !row.isChecked {
        Button("Pas trouvé", systemImage: "questionmark.circle") { session.markNotFound(row) }
          .tint(Palette.Aisle.grocery)
      }
    }
    .contextMenu {
      if !row.isChecked {
        Button("Pas trouvé", systemImage: "questionmark.circle") { session.markNotFound(row) }
      }
    }
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
      ItemLine(label: row.label, quantity: row.quantity, isChecked: row.isChecked)
    }
    .buttonStyle(.plain)
    .ticketRow()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
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
    TextField("Ajouter un article", text: $session.input, prompt: EntryPrompt.text)
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
    .prominentButton()
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
