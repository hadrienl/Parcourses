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
      Section {
        ForEach(session.toBuy) { row in
          itemRow(row)
        }
      } header: {
        header
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
    .scrollDismissesKeyboard(.interactively)
    .onScrollPhaseChange { _, phase in session.setScrolling(phase.isScrolling) }
    .onChange(of: inputIsFocused) { _, focused in session.setEditing(focused) }
    .onChange(of: session.input) { session.setEditing(inputIsFocused) }
    .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in session.syncDidChange() }
    .navigationTitle(session.name)
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.success, trigger: checkTrigger)
    .safeAreaInset(edge: .bottom) { dock }
    .sheet(isPresented: remainingIsPresented) {
      RemainingItemsSheet(
        count: session.remainingCount, canCancel: !session.expired,
        onKeep: { session.finish(keepRemaining: true) }, onDrop: { session.finish(keepRemaining: false) },
        onCancel: { showsRemaining = false }
      )
      .presentationDetents([.medium])
      .interactiveDismissDisabled(session.expired)
    }
    .alert("Erreur", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) { session.errorMessage = nil }
    } message: {
      Text(session.errorMessage ?? "")
    }
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
      Text(remainingText)
        .font(.title2.weight(.bold))
        .foregroundStyle(.primary)
      if let store = session.storeName {
        Text(store).font(.subheadline)
      }
      Text(knowledgeText).font(.subheadline)
    }
    .textCase(nil)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("shoppingHeader")
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
      HStack {
        // L'état se lit sans couleur : forme de l'icône et texte barré.
        Image(systemName: row.isChecked ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(row.isChecked ? Color.accentColor : .secondary)
        Text(row.label)
          .strikethrough(row.isChecked)
          .foregroundStyle(row.isChecked ? .secondary : .primary)
        Spacer()
        if let quantity = row.quantity {
          Text(quantity).foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(session.highlightedItemId == row.id ? Color.accentColor.opacity(0.2) : nil)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.isChecked ? "coché" : "non coché")
    .accessibilityAddTraits(.isToggle)
    .accessibilityAction(named: "Pas trouvé") { if !row.isChecked { session.markNotFound(row) } }
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
      HStack {
        Image(systemName: "questionmark.circle")
        Text(row.label)
        Spacer()
        Text("Remettre").font(.subheadline)
      }
      .foregroundStyle(.secondary)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue("introuvable")
    .accessibilityHint("Remet l'article dans la liste")
  }

  private var dock: some View {
    VStack(spacing: 8) {
      if let undo = session.undo {
        HStack {
          Text(undo.message).lineLimit(2)
          Spacer()
          Button("Annuler") { session.performUndo() }
            .fontWeight(.semibold)
            .frame(minHeight: 44)
            .accessibilityIdentifier("undo")
        }
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity)
      }
      if session.isEverythingChecked {
        Text("Tout est coché !").font(.headline)
      }
      HStack {
        TextField("Ajouter un article", text: $session.input)
          .textFieldStyle(.roundedBorder)
          .focused($inputIsFocused)
          .submitLabel(.done)
          .accessibilityIdentifier("shoppingEntry")
          .onSubmit(submit)
        Button("Terminer", action: finishTapped)
          .buttonStyle(.borderedProminent)
          .frame(minHeight: 44)
          .accessibilityIdentifier("finish")
      }
    }
    .animation(motion, value: session.undo)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
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
    VStack(spacing: 16) {
      Text(count == 1 ? "1 article non coché" : "\(count) articles non cochés")
        .font(.title2.weight(.bold))
      Text("Les garder pour la prochaine fois ?")
      Button("Les garder", action: onKeep)
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .accessibilityIdentifier("keepRemaining")
      Button("Les retirer de la liste", role: .destructive, action: onDrop)
        .frame(minHeight: 44)
      if canCancel {
        Button("Continuer mes courses", action: onCancel)
          .frame(minHeight: 44)
      }
    }
    .padding()
  }
}

/// Fin des courses : « 12 articles en 18 min » et la contribution.
struct ShoppingSummaryView: View {
  let summary: ShoppingSummary
  let onClose: () -> Void
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
      Text(summary.checkedCount <= 1 ? "\(summary.checkedCount) article" : "\(summary.checkedCount) articles")
        .font(.largeTitle.weight(.bold))
      Text("en \(summary.minutes) min").font(.title2)
      if let contribution {
        Text(contribution).multilineTextAlignment(.center).foregroundStyle(.secondary)
          .accessibilityIdentifier("contribution")
      }
      Spacer()
      Button("Retour aux listes", action: onClose)
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .accessibilityIdentifier("closeSummary")
    }
    .padding()
    .sensoryFeedback(.success, trigger: appeared)
    .onAppear { appeared = true }
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
