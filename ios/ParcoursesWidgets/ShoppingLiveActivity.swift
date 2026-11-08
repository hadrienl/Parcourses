import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity du mode courses : progression, prochain article et son rayon. Habillage système : l'identité
/// visuelle arrive en 9.11.
struct ShoppingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ShoppingActivityAttributes.self) { context in
      LockScreenView(attributes: context.attributes, state: context.state)
        .padding()
        .activityBackgroundTint(nil)
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          ProgressRing(state: state).frame(width: 44, height: 44)
        }
        DynamicIslandExpandedRegion(.center) {
          NextItemView(state: state)
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
        ProgressRing(state: state)
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

  var body: some View {
    HStack(spacing: 12) {
      ProgressRing(state: state).frame(width: 48, height: 48)
      VStack(alignment: .leading, spacing: 2) {
        Text(attributes.storeName ?? attributes.listName)
          .font(.caption)
          .foregroundStyle(.secondary)
        NextItemView(state: state)
        Text(summary(state))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Prochain article et son rayon, ou le message de fin.
private struct NextItemView: View {
  let state: ShoppingActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if state.isFinished {
        Text("Courses terminées").font(.headline)
      } else if let label = state.nextItemLabel {
        Text(label).font(.headline).lineLimit(1)
        if let category = state.nextCategoryLabel {
          Text(category).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      } else {
        Text("Tout est pris").font(.headline)
      }
    }
  }
}

/// Anneau de progression avec le nombre d'articles restants.
private struct ProgressRing: View {
  let state: ShoppingActivityAttributes.ContentState

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
        Text("\(state.remaining)").font(.caption.bold()).monospacedDigit()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary(state))
  }
}
