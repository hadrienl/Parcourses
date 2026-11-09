import SwiftUI
import UIKit

/// Mode courses, plein écran. Habillage système : l'identité visuelle arrive en 9.11.
struct ShoppingView: View {
  @State var session: ShoppingSession
  let onClose: () -> Void
  @State private var showsRemaining = false
  @State private var basketIsExpanded = false
  @State private var checkTrigger = 0
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

  private var motion: Animation {
    reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0)
  }

  private var shopping: some View {
    List {
      if session.groupsByAisle {
        // Ordre non appris : un titre par rayon. L'en-tête de la visite ouvre la liste, sans ligne.
        Section {
        } header: {
          header
        }
        ForEach(session.sections) { section in
          Section {
            ForEach(section.rows) { row in
              itemRow(row)
            }
          } header: {
            aisleHeader(section)
          }
        }
      } else {
        Section {
          ForEach(session.toBuy) { row in
            itemRow(row)
          }
        } header: {
          header
        }
      }
      if !session.notFound.isEmpty {
        Section("Introuvable") {
          ForEach(session.notFound) { row in
            notFoundRow(row)
          }
        }
      }
      if !session.basket.isEmpty {
        Section {
          DisclosureGroup("Dans le panier (\(session.basket.count))", isExpanded: $basketIsExpanded) {
            ForEach(session.basket) { row in
              itemRow(row)
            }
          }
          .accessibilityIdentifier("basket")
        }
      }
    }
    .animation(motion, value: session.toBuy.map(\.id))
    .animation(motion, value: session.basket.map(\.id))
    .onChange(of: session.toBuy.map(\.id)) { old, new in listDidChange(from: old, to: new) }
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
    .navigationTitle(session.name)
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.success, trigger: checkTrigger)
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
      .presentationBackground(Color(uiColor: .systemBackground))
      .interactiveDismissDisabled(session.expired)
    }
    .alert("Erreur", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) { session.errorMessage = nil }
    } message: {
      Text(session.errorMessage ?? "")
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      // `Color.primary`, pas `.primary` : dans un en-tête de section, le style hiérarchique reste gris.
      // Aucune ligne tronquée aux grandes tailles de texte.
      VStack(alignment: .leading, spacing: 2) {
        Text(remainingText)
          .font(.title2.weight(.bold))
        if let store = session.storeName {
          Text(store).font(.subheadline)
        }
        Text(knowledgeText).font(.subheadline)
      }
      .foregroundStyle(Color.primary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("shoppingHeader")
      // Le magasin vient d'OpenStreetMap : l'attribution reste là où son nom s'affiche.
      if session.storeName != nil { OSMAttribution() }
    }
    .textCase(nil)
    .padding(.bottom, 8)
  }

  /// Titre de rayon : lu comme un en-tête, avec le nombre d'articles à prendre. Taille et casse du système,
  /// qui suivent Dynamic Type.
  private func aisleHeader(_ section: ShoppingSection) -> some View {
    Text(section.title)
      .font(.headline)
      .foregroundStyle(Color.primary)
      .fixedSize(horizontal: false, vertical: true)
      .textCase(nil)
      .accessibilityLabel(section.accessibilityLabel)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("aisle-\(section.aisleId)")
  }

  private var remainingText: String {
    let count = session.toBuy.filter { !$0.isChecked }.count
    return count <= 1 ? "\(count) restant" : "\(count) restants"
  }

  private var knowledgeText: String {
    switch session.knowledge {
    case .noStore: "Sans magasin : ordre par rayon"
    case .unknown: "Vous tracez le premier trajet ici"
    case .learning(let percent): "Trajet en apprentissage (\(percent) %)"
    case .learned(let percent): "Trajet connu à \(percent) %"
    }
  }

  private func itemRow(_ row: ShoppingRow) -> some View {
    Button {
      if !row.isChecked { checkTrigger += 1 }
      session.toggle(row)
    } label: {
      // L'état se lit sans couleur : forme de l'icône et texte barré.
      ItemLine(label: row.label, quantity: row.quantity, isChecked: row.isChecked)
    }
    .buttonStyle(.plain)
    .listRowBackground(
      session.highlightedItemId == row.id ? Color.accentColor.opacity(contrast == .increased ? 0.4 : 0.2) : nil
    )
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
          .tint(.orange)
      }
    }
    .contextMenu {
      if !row.isChecked {
        Button("Pas trouvé", systemImage: "questionmark.circle") { session.markNotFound(row) }
      }
    }
  }

  private func notFoundRow(_ row: ShoppingRow) -> some View {
    Button {
      session.restore(row)
    } label: {
      ViewThatFits(in: .horizontal) {
        HStack {
          Image(systemName: "questionmark.circle")
          Text(row.label)
          Spacer()
          Text("Remettre").font(.subheadline)
        }
        VStack(alignment: .leading) {
          Label(row.label, systemImage: "questionmark.circle")
          Text("Remettre").font(.subheadline)
        }
      }
      .foregroundStyle(contrast == .increased ? .primary : .secondary)
      .rowHeight()
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue("introuvable")
    .accessibilityHint("Remet l'article dans la liste")
  }

  private var dock: some View {
    VStack(spacing: 8) {
      if let undo = session.undo {
        ViewThatFits(in: .horizontal) {
          HStack {
            Text(undo.message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("undoMessage")
            Spacer()
            undoButton
          }
          VStack(alignment: .leading, spacing: 0) {
            Text(undo.message).accessibilityIdentifier("undoMessage")
            undoButton
          }
        }
        .padding(.horizontal, 12)
        .bannerBackground()
        .transition(.opacity)
      }
      if session.isEverythingChecked {
        Text("Tout est coché !").font(.headline).accessibilityIdentifier("allChecked")
      }
      // Aux grandes tailles de texte, « Terminer » passe sous le champ.
      ViewThatFits(in: .horizontal) {
        HStack {
          entryField
          finishButton
        }
        VStack(spacing: 8) {
          entryField
          finishButton
        }
      }
    }
    .animation(motion, value: session.undo)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .barBackground()
  }

  private var undoButton: some View {
    Button {
      session.performUndo()
    } label: {
      // Jamais tronqué : si la place manque, `ViewThatFits` passe le bouton sous le message.
      Text("Annuler").fontWeight(.semibold).fixedSize().touchTarget()
    }
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
          .font(.title2.weight(.bold))
        Text("Les garder pour la prochaine fois ?")
        Button("Les garder", action: onKeep)
          .prominentButton()
          .accessibilityIdentifier("keepRemaining")
        Button(role: .destructive, action: onDrop) {
          Text("Les retirer de la liste").touchTarget()
        }
        if canCancel {
          Button(action: onCancel) {
            Text("Continuer mes courses").touchTarget()
          }
        }
      }
      .multilineTextAlignment(.center)
      .padding()
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}

/// Fin des courses : « 12 articles en 18 min » et la contribution.
struct ShoppingSummaryView: View {
  let summary: ShoppingSummary
  let onClose: () -> Void
  @State private var appeared = false

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
    .sensoryFeedback(.success, trigger: appeared)
    .onAppear { appeared = true }
  }

  private var summaryContent: some View {
    VStack(spacing: 16) {
      Text(summary.checkedCount <= 1 ? "\(summary.checkedCount) article" : "\(summary.checkedCount) articles")
        .font(.largeTitle.weight(.bold))
      Text("en \(summary.minutes) min").font(.title2)
      if let contribution {
        Text(contribution).multilineTextAlignment(.center).foregroundStyle(.secondary)
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
