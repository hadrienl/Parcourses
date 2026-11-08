import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity du mode courses : progression, prochain article et son rayon. Habillage système : l'identité
/// visuelle arrive en 9.11.
struct ShoppingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ShoppingActivityAttributes.self) { context in
      LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
        .padding()
        .activityBackgroundTint(nil)
    } dynamicIsland: { context in
      let state = context.state
      let isStale = context.isStale
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          ProgressRing(state: state)
            .accessibilityHidden(true)
        }
        DynamicIslandExpandedRegion(.center) {
          NextItemView(state: state, isStale: isStale)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(summary(state))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } compactLeading: {
        Image(systemName: "cart")
          .accessibilityHidden(true)
      } compactTrailing: {
        Text(state.isFinished ? "OK" : "\(state.remaining)")
          .monospacedDigit()
          .accessibilityLabel(summary(state))
      } minimal: {
        ProgressRing(state: state, baseSize: 24)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(summary(state))
      }
    }
  }
}

private func summary(_ state: ShoppingActivityAttributes.ContentState) -> String {
  if state.isFinished { return "Courses terminées" }
  return state.remaining <= 1
    ? "\(state.remaining) article restant sur \(state.total)"
    : "\(state.remaining) articles restants sur \(state.total)"
}

private struct LockScreenView: View {
  let attributes: ShoppingActivityAttributes
  let state: ShoppingActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(spacing: 12) {
      // L'anneau répète le texte de dessous : VoiceOver ne le lit pas.
      ProgressRing(state: state)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(attributes.storeName ?? attributes.listName)
          .font(.caption)
          .foregroundStyle(.secondary)
        NextItemView(state: state, isStale: isStale)
        Text(summary(state))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Prochain article et son rayon, ou le message de fin. Le libellé reste visible sur l'écran verrouillé (c'est
/// l'intérêt de l'activité) mais est masqué quand le système juge l'écran sensible.
private struct NextItemView: View {
  let state: ShoppingActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if state.isFinished {
        Text("Courses terminées").font(.headline)
      } else if isStale {
        // Plus de coche depuis longtemps : la visite se terminera à la réouverture de l'app.
        Text("Visite inactive").font(.headline)
      } else if let label = state.nextItemLabel {
        Text(label)
          .font(.headline)
          .lineLimit(2)
          .privacySensitive()
        if let category = state.nextCategoryLabel {
          Text(category).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      } else {
        Text("Tout est pris").font(.headline)
      }
    }
  }
}

/// Anneau de progression avec le nombre d'articles restants. Sa taille suit Dynamic Type, chiffre compris.
private struct ProgressRing: View {
  let state: ShoppingActivityAttributes.ContentState
  @ScaledMetric private var size: Double

  init(state: ShoppingActivityAttributes.ContentState, baseSize: Double = 44) {
    self.state = state
    _size = ScaledMetric(wrappedValue: baseSize, relativeTo: .caption)
  }

  var body: some View {
    ZStack {
      Circle().stroke(.quaternary, lineWidth: 4)
      Circle()
        .trim(from: 0, to: state.isFinished ? 1 : state.progress)
        .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90))
      if state.isFinished {
        Image(systemName: "checkmark").font(.caption.bold())
      } else {
        Text("\(state.remaining)")
          .font(.caption.bold())
          .monospacedDigit()
          .minimumScaleFactor(0.5)
          .lineLimit(1)
          .padding(6)
      }
    }
    .frame(width: size, height: size)
  }
}
