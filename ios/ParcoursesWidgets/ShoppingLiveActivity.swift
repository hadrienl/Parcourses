import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// Live Activity du mode courses, habillée en ticket filé (B3, #6, #52) : papier, encre et accent du ticket, chasse
/// fixe, fil du parcours qui avance à chaque coche, nœud du rayon de l'article suivant. Sans le ton de B1 : ni
/// papier thermique, ni perforations, ni tampon. La Dynamic Island reste sur le fond noir du système, avec les
/// couleurs sombres du ticket.
struct ShoppingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ShoppingActivityAttributes.self) { context in
      LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
        .padding(Space.m)
        .activityBackgroundTint(Palette.paper)
        .activitySystemActionForegroundColor(Palette.ink)
    } dynamicIsland: { context in
      let attributes = context.attributes
      let state = context.state
      let isStale = context.isStale
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          NextAisleNode(state: state)
            .padding(.leading, Space.xs / 2)
            .islandInk()
        }
        DynamicIslandExpandedRegion(.trailing) {
          // Étroit : les chiffres seuls, sans la légende « RESTE ».
          RemainingCounter(state: state, showsCaption: false)
            .padding(.trailing, Space.xs / 2)
            .islandInk()
        }
        DynamicIslandExpandedRegion(.center) {
          NextItemView(state: state, isStale: isStale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .islandInk()
        }
        // L'îlot étendu est bas : le nœud du rayon et le compteur y tiennent lieu de fil.
        DynamicIslandExpandedRegion(.bottom) {
          CheckNextButton(attributes: attributes, state: state, isStale: isStale, fullWidth: true)
            .islandInk()
        }
      } compactLeading: {
        CompactAisleIcon(state: state)
          .islandInk()
      } compactTrailing: {
        Text(state.isFinished ? "OK" : TicketCounter.text(state.remaining))
          .font(.system(.callout, design: .monospaced).weight(.heavy))
          .monospacedDigit()
          .minimumScaleFactor(0.6)
          .lineLimit(1)
          .foregroundStyle(Palette.accent)
          .accessibilityLabel(summary(state))
          .islandInk()
      } minimal: {
        ProgressRing(state: state)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(summary(state))
          .islandInk()
      }
      .keylineTint(islandAccent)
    }
  }
}

private func summary(_ state: ShoppingActivityAttributes.ContentState) -> String {
  if state.isFinished { return "Courses terminées" }
  return state.remaining <= 1
    ? "\(state.remaining) article restant sur \(state.total)"
    : "\(state.remaining) articles restants sur \(state.total)"
}

/// Accent du ticket en sombre, pour la teinte du contour de l'îlot (résolue hors de l'environnement des vues).
private let islandAccent = Color(
  uiColor: UIColor(Palette.accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))

extension View {
  /// La Dynamic Island est toujours noire : les jetons du ticket y prennent leur valeur sombre.
  fileprivate func islandInk() -> some View {
    environment(\.colorScheme, .dark)
  }
}

private struct LockScreenView: View {
  let attributes: ShoppingActivityAttributes
  let state: ShoppingActivityAttributes.ContentState
  let isStale: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    // La carte est limitée en hauteur (160 pt) : dès les grandes tailles de texte, le fil, le nœud et le magasin
    // cèdent la place au texte et au bouton, qui passe dessous.
    let large = dynamicTypeSize >= .xxLarge
    VStack(alignment: .leading, spacing: Space.xs) {
      if !large {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
          // Magasin et liste situent la personne : masqués sur l'écran verrouillé, comme la version publique de la
          // notification Android (« Courses en cours · N articles restants sur T »).
          Text(attributes.storeName ?? attributes.listName)
            .font(.system(.headline, design: .monospaced).weight(.heavy))
            .tracking(TicketFont.titleTracking)
            .textCase(.uppercase)
            .lineLimit(1)
            .foregroundStyle(Palette.ink)
            .privacySensitive()
          Spacer(minLength: 0)
          RemainingCounter(state: state)
        }
        ThreadProgress(state: state)
      }
      HStack(spacing: Space.s) {
        if !large { NextAisleNode(state: state) }
        NextItemView(state: state, isStale: isStale)
        Spacer(minLength: 0)
        if !large { CheckNextButton(attributes: attributes, state: state, isStale: isStale, fullWidth: false) }
      }
      if large {
        Text(summary(state)).font(TicketFont.meta).foregroundStyle(Palette.inkMuted)
        CheckNextButton(attributes: attributes, state: state, isStale: isStale, fullWidth: true)
      }
    }
  }
}

/// « RESTE 05 », comme l'en-tête du ticket. VoiceOver lit la phrase complète.
private struct RemainingCounter: View {
  let state: ShoppingActivityAttributes.ContentState
  var showsCaption = true

  var body: some View {
    HStack(alignment: .lastTextBaseline, spacing: Space.xs / 2) {
      if state.isFinished {
        Image(systemName: "checkmark")
          .font(.system(.title2, design: .monospaced).weight(.heavy))
          .foregroundStyle(Palette.accent)
      } else {
        if showsCaption {
          Text("Reste")
            .font(TicketFont.totalCaption)
            .tracking(TicketFont.aisleTracking)
            .textCase(.uppercase)
            .foregroundStyle(Palette.inkMuted)
        }
        Text(TicketCounter.text(state.remaining))
          .font(.system(.title2, design: .monospaced).weight(.heavy))
          .tracking(TicketFont.totalTracking / 2)
          .monospacedDigit()
          .foregroundStyle(Palette.ink)
          .contentTransition(.numericText(countsDown: true))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary(state))
  }
}

/// Fil du parcours : parcouru à l'accent jusqu'à la perle de l'article suivant, à parcourir en `threadIdle`.
/// Décoratif : le compteur dit la même chose.
private struct ThreadProgress: View {
  let state: ShoppingActivityAttributes.ContentState
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let progress = state.isFinished ? 1 : state.progress
    let width = contrast == .increased ? TicketMetrics.threadWidthIncreased : TicketMetrics.threadWidth
    GeometryReader { proxy in
      let inset = TicketMetrics.beadNext / 2
      let track = max(0, proxy.size.width - 2 * inset)
      let x = inset + track * progress
      ZStack(alignment: .leading) {
        Capsule().fill(Palette.threadIdle).frame(height: width).padding(.horizontal, inset)
        Capsule().fill(Palette.thread).frame(width: max(0, x - inset), height: width).offset(x: inset)
        Bead(state: .done).position(x: inset, y: proxy.size.height / 2)
        Bead(state: state.isFinished ? .done : .next).position(x: x, y: proxy.size.height / 2)
      }
    }
    .frame(height: TicketMetrics.beadNext)
    .accessibilityHidden(true)
  }
}

/// Nœud du rayon de l'article suivant, comme sur le fil du ticket. Rien sans article à prendre.
private struct NextAisleNode: View {
  let state: ShoppingActivityAttributes.ContentState
  @Environment(\.redactionReasons) private var redactionReasons

  var body: some View {
    Group {
      // Écran verrouillé masqué : l'icône du rayon (bébé, alcool…) en dirait autant que son libellé.
      if let aisleId = state.nextAisleId, !state.isFinished, !redactionReasons.contains(.privacy) {
        AisleNode(aisleId: aisleId)
      } else {
        Bead(state: .done)
          .frame(width: TicketMetrics.aisleNode, height: TicketMetrics.aisleNode)
      }
    }
    .accessibilityHidden(true)
  }
}

/// Îlot compact : l'icône du rayon suivant, à sa couleur ; une coche à la fin.
private struct CompactAisleIcon: View {
  let state: ShoppingActivityAttributes.ContentState
  @Environment(\.redactionReasons) private var redactionReasons

  var body: some View {
    Group {
      if state.isFinished {
        Image(systemName: "checkmark").font(.body.weight(.heavy)).foregroundStyle(Palette.accent)
      } else if let aisleId = state.nextAisleId, !redactionReasons.contains(.privacy) {
        Image(AisleStyle.iconName(aisleId))
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .frame(width: TicketMetrics.aisleIcon, height: TicketMetrics.aisleIcon)
          .foregroundStyle(AisleStyle.color(aisleId))
      } else {
        Image(systemName: "cart").foregroundStyle(Palette.accent)
      }
    }
    .accessibilityHidden(true)
  }
}

/// « Cocher le suivant » (#10 §9) : coche l'article affiché, sans ouvrir l'app. Seulement pendant une visite
/// active : ni sans magasin (aucune visite à suivre), ni périmée, ni terminée, ni sans article à prendre.
/// Bouton plein du ticket (`accent` / `onAccent`), 44 pt.
private struct CheckNextButton: View {
  let attributes: ShoppingActivityAttributes
  let state: ShoppingActivityAttributes.ContentState
  let isStale: Bool
  /// Seul sous le texte (îlot étendu, tailles d'accessibilité) ; sinon pastille à droite de l'article.
  let fullWidth: Bool
  @Environment(\.redactionReasons) private var redactionReasons

  /// VoiceOver nomme l'article coché.
  private var accessibilityName: String {
    state.nextItemLabel.map { "Cocher \($0)" } ?? "Cocher le suivant"
  }

  var body: some View {
    // Écran verrouillé, article masqué : pas de bouton, on ne coche pas un article qu'on ne voit pas (comme la
    // version publique de la notification Android, sans action).
    if let visitId = attributes.visitId, let itemId = state.nextItemId, !isStale, !state.isFinished,
      !redactionReasons.contains(.privacy)
    {
      // Un intent par article : un toucher sur un affichage dépassé ne coche pas l'article suivant.
      Button(intent: CheckNextItemIntent(visitId: visitId, itemId: itemId)) {
        Label(fullWidth ? "Cocher le suivant" : "Cocher", systemImage: "checkmark")
          .font(.system(.subheadline, design: .monospaced).weight(.bold))
          .foregroundStyle(Palette.onAccent)
          .padding(.horizontal, Space.s)
          .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: TicketMetrics.touchMin)
          .background(Palette.accent, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityName)
      // Commande vocale : le libellé visible, court ou long.
      .accessibilityInputLabels([Text("Cocher"), Text("Cocher le suivant"), Text(accessibilityName)])
    }
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
        title("Courses terminées")
      } else if isStale {
        // Plus de coche depuis longtemps : la visite se terminera à la réouverture de l'app.
        title("Visite inactive")
      } else if let label = state.nextItemLabel {
        if let category = state.nextCategoryLabel {
          // Titre du rayon comme sur le ticket : capitales espacées en couleur secondaire.
          Text(category)
            .font(TicketFont.aisle)
            .tracking(TicketFont.aisleTracking)
            .textCase(.uppercase)
            .foregroundStyle(Palette.inkMuted)
            .lineLimit(1)
            .privacySensitive()
        }
        Text(label)
          .font(TicketFont.itemNext)
          .foregroundStyle(Palette.ink)
          .lineLimit(2)
          .privacySensitive()
      } else {
        title("Tout est pris")
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func title(_ text: String) -> some View {
    Text(text).font(TicketFont.itemNext).foregroundStyle(Palette.ink)
  }
}

/// Îlot minimal : anneau du fil, parcouru à l'accent, avec le nombre d'articles restants.
private struct ProgressRing: View {
  let state: ShoppingActivityAttributes.ContentState

  var body: some View {
    ZStack {
      // Sur le noir de l'îlot, `threadIdle` sombre disparaît (1,7:1) : la piste prend le texte secondaire.
      Circle().stroke(Palette.inkMuted.opacity(0.6), lineWidth: TicketMetrics.threadWidth)
      Circle()
        .trim(from: 0, to: state.isFinished ? 1 : state.progress)
        .stroke(Palette.thread, style: StrokeStyle(lineWidth: TicketMetrics.threadWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
      if state.isFinished {
        Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(Palette.accent)
      } else {
        Text("\(state.remaining)")
          .font(.system(.caption2, design: .monospaced).weight(.heavy))
          .monospacedDigit()
          .foregroundStyle(Palette.ink)
          .minimumScaleFactor(0.5)
          .lineLimit(1)
          .padding(4)
      }
    }
  }
}
