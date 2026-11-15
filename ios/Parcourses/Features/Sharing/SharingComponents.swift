import SwiftUI

/// Avatar d'un membre : initiale en chasse fixe sur le bord du papier, cercle (jeton `sharing.avatar`). Décoratif : le
/// prénom passe dans le libellé du bouton ou de la ligne.
struct MemberAvatar: View {
  let label: String
  var size: CGFloat = 28
  /// Anneau couleur papier qui sépare les pastilles empilées.
  var ring = true
  /// Suit Dynamic Type : avatar posé dans le contenu, comme celui de la carte d'invitation. L'initiale prend alors un
  /// style de texte (`subheadline`, la taille de l'initiale d'un avatar de 36 pt à la taille par défaut), et le cercle
  /// grandit avec lui. Les pastilles de la barre et des lignes gardent leur taille, la barre ne s'agrandit pas.
  var scalesWithText = false
  @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

  var body: some View {
    let side = scalesWithText ? size * scale : size
    Text(label)
      .font(
        scalesWithText
          ? .system(.subheadline, design: .monospaced).weight(.bold)
          : .system(size: size * 0.43, weight: .bold, design: .monospaced)
      )
      .foregroundStyle(Palette.ink)
      .lineLimit(1)
      .minimumScaleFactor(scalesWithText ? 1 : 0.6)
      .frame(width: side, height: side)
      .background(Palette.paperEdge, in: Circle())
      .overlay { if ring { Circle().strokeBorder(Palette.paper, lineWidth: 2) } }
      .accessibilityHidden(true)
  }
}

/// Pastilles empilées (8 pt de recouvrement). Aux tailles d'accessibilité, une seule pastille porte le nombre.
struct AvatarStack: View {
  let labels: [String]
  var size: CGFloat = 28
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    if typeSize >= .accessibility3, labels.count > 1 {
      MemberAvatar(label: "\(labels.count)", size: size)
    } else {
      HStack(spacing: -8) {
        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
          MemberAvatar(label: label, size: size)
        }
      }
    }
  }
}

/// Marque d'auteur d'un article : initiale de 20 pt au trait, après la quantité. Décorative.
struct AuthorMark: View {
  let initial: String

  var body: some View {
    Text(initial)
      .font(.system(size: 9, weight: .bold, design: .monospaced))
      .foregroundStyle(Palette.inkMuted)
      .frame(width: 20, height: 20)
      .overlay { Circle().strokeBorder(Palette.inkMuted, lineWidth: 1) }
      .accessibilityHidden(true)
  }
}

/// Badge « PARTAGÉE » ou « LECTURE SEULE » (jeton `sharing.badge`).
struct SharingBadge: View {
  enum Kind {
    case shared
    case readOnly
  }

  let kind: Kind

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    Label(kind == .shared ? "Partagée" : "Lecture seule", systemImage: kind == .shared ? "person.2" : "eye")
      .font(.system(.caption2, design: .monospaced).weight(.bold))
      .textCase(.uppercase)
      .tracking(0.8)
      .foregroundStyle(kind == .shared ? Palette.accent : Palette.ink)
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(kind == .shared ? Color.clear : Palette.paperEdge, in: shape)
      .overlay { if kind == .shared { shape.strokeBorder(Palette.accent, lineWidth: 1) } }
  }
}

/// Encart d'avertissement (e-mail non parti, autre adresse, accès abaissé) : fond `cautionFill`, filet `caution`.
struct CautionCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous)
    VStack(alignment: .leading, spacing: Space.xs) {
      content
    }
    .foregroundStyle(Palette.ink)
    .padding(Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.Sharing.cautionFill, in: shape)
    .overlay { shape.strokeBorder(Palette.Sharing.caution, lineWidth: 1) }
  }
}

/// Message bref, en papier au-dessus du bas de l'écran ; disparaît seul et s'annonce à VoiceOver.
struct SharingToast: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.callout)
      .foregroundStyle(Palette.ink)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, Space.m)
      .padding(.vertical, Space.s)
      .frame(minHeight: 44)
      .ticketBanner()
      .padding(.horizontal, Space.m)
      .padding(.bottom, Space.xs)
      .accessibilityIdentifier("sharingToast")
  }
}

extension View {
  /// Capsule qui affiche `message` 4 s, l'annonce à VoiceOver, puis appelle `dismiss`.
  func sharingToast(_ message: String?, revision: Int, dismiss: @escaping () -> Void) -> some View {
    safeAreaInset(edge: .bottom) {
      if let message {
        SharingToast(message: message)
          .transition(.opacity)
          .task(id: revision) {
            AccessibilityNotification.Announcement(message).post()
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dismiss()
          }
      }
    }
  }
}

extension View {
  /// Remplace le libellé lu seulement si `label` est donné.
  @ViewBuilder func accessibilityLabel(override label: String?) -> some View {
    if let label {
      accessibilityLabel(label)
    } else {
      self
    }
  }
}
