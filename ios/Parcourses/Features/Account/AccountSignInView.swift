import SwiftUI

extension AccountLink: Identifiable {}

/// Feuille « Se connecter » (#87, maquette `design/sharing-v1.html`, écran 4) : adresse (et prénom pour un compte
/// anonyme), puis code à 6 chiffres, puis « Rapprochement de vos listes… » et « Bon retour » pour un compte existant.
struct AccountSignInView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var link: AccountLink
  /// Liaison ou connexion terminée : le compte est relu.
  let onFinish: () -> Void

  @State private var code = ""
  @State private var canResend = false
  @FocusState private var focus: Field?
  @AccessibilityFocusState private var titleFocused: Bool

  private enum Field: Hashable {
    case email
    case name
    case code
  }

  init(link: AccountLink, onFinish: @escaping () -> Void) {
    _link = State(initialValue: link)
    self.onFinish = onFinish
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.m) {
          switch link.phase {
          case .enterEmail: emailStep
          case .enterCode: codeStep
          case .merging: mergingStep
          case .done: doneStep
          }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollDismissesKeyboard(.interactively)
      .ticketBackground()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if link.phase == .enterEmail || link.phase == .enterCode {
          ToolbarItem(placement: .cancellationAction) {
            Button("Fermer") { dismiss() }
              .disabled(link.isWorking)
              .accessibilityIdentifier("closeSignIn")
          }
        }
      }
    }
    // Rapprochement en cours : rien ne ferme la feuille avant son issue.
    .interactiveDismissDisabled(link.phase == .merging || link.isWorking)
    .onChange(of: link.errorRevision) {
      guard let message = errorMessage else { return }
      if link.phase == .enterCode {
        // Le champ se vide et garde le focus (maquette, écran 4).
        code = ""
        focus = .code
      }
      AccessibilityNotification.Announcement(message).post()
    }
    .onChange(of: link.phase) { _, phase in
      switch phase {
      case .enterEmail: focus = .email
      case .enterCode:
        code = ""
        focus = .code
      case .merging:
        AccessibilityNotification.Announcement("Rapprochement de vos listes…").post()
      case .done:
        onFinish()
        titleFocused = true
      }
    }
  }

  // MARK: - Adresse

  @ViewBuilder private var emailStep: some View {
    Text("Se connecter")
      .font(TicketFont.title)
      .foregroundStyle(Palette.ink)
      .accessibilityAddTraits(.isHeader)
    Text("Retrouvez vos listes et celles qu'on partage avec vous.")
      .foregroundStyle(Palette.ink)
    if link.losesPendingChangesOnSwitch {
      // Compte e-mail sans session : une autre adresse purgerait l'appareil (#87, changement de compte).
      Label(
        "Avec une autre adresse, les listes de cet appareil en seront retirées. Les modifications pas encore envoyées seront perdues.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.callout)
      .foregroundStyle(Palette.ink)
      .accessibilityIdentifier("switchWarning")
    }
    field(label: "Adresse e-mail") {
      TextField("prenom@exemple.fr", text: $link.email)
        .textContentType(.emailAddress)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(link.canLink ? .next : .send)
        .focused($focus, equals: .email)
        .onSubmit {
          if link.canLink {
            focus = .name
          } else {
            request()
          }
        }
        .accessibilityIdentifier("accountEmailField")
    }
    if link.canLink {
      field(label: "Prénom (facultatif)") {
        TextField("Prénom", text: $link.displayName)
          .textContentType(.givenName)
          .submitLabel(.send)
          .focused($focus, equals: .name)
          .onSubmit(request)
          .accessibilityIdentifier("accountNameField")
      }
      Text(
        link.isNameAcceptable
          ? "Les personnes avec qui vous partagez une liste verront ce prénom."
          : "Entre 1 et 40 caractères, sans adresse ni lien."
      )
      .font(.footnote)
      .foregroundStyle(link.isNameAcceptable ? Palette.inkMuted : Palette.ink)
    }
    errorLine
    Button(action: request) {
      HStack(spacing: Space.xs) {
        if link.isWorking { ProgressView().tint(Palette.onAccent) }
        Text(link.isWorking ? "Envoi…" : "Recevoir un code")
      }
      .frame(maxWidth: .infinity)
    }
    .prominentButton()
    .disabled(!link.canRequestCode)
    .accessibilityIdentifier("requestCode")
    .onAppear { focus = .email }
  }

  private func request() {
    guard link.canRequestCode else { return }
    Task { await link.requestCode() }
  }

  // MARK: - Code

  @ViewBuilder private var codeStep: some View {
    Text("Entrez le code")
      .font(TicketFont.title)
      .foregroundStyle(Palette.ink)
      .accessibilityAddTraits(.isHeader)
    VStack(alignment: .leading, spacing: 2) {
      Text("Envoyé à")
      // L'adresse peut se couper n'importe où.
      Text(link.sentTo ?? "").bold().textSelection(.enabled)
      Text("Il expire dans 15 minutes.")
    }
    .foregroundStyle(Palette.ink)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Envoyé à \(link.sentTo ?? ""). Il expire dans 15 minutes.")
    CodeEntryField(code: $code, length: AccountLink.codeLength, hasError: link.error != nil)
      .focused($focus, equals: .code)
      .disabled(link.isWorking)
      .onChange(of: code) { _, value in
        let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(AccountLink.codeLength))
        if digits != value { code = digits }
        // Validation automatique au 6ᵉ chiffre.
        if digits.count == AccountLink.codeLength { Task { await link.verify(code: digits) } }
      }
    errorLine
    if link.isWorking {
      HStack(spacing: Space.xs) {
        ProgressView()
        Text("Vérification…")
      }
      .frame(maxWidth: .infinity)
      .foregroundStyle(Palette.ink)
      .accessibilityElement(children: .combine)
      .onAppear { AccessibilityNotification.Announcement("Vérification…").post() }
    }
    resendButton
    Button("Changer d'adresse") {
      code = ""
      link.changeEmail()
    }
    .frame(maxWidth: .infinity)
    .touchTarget()
    .disabled(link.isWorking)
    .accessibilityIdentifier("changeEmail")
  }

  private var resendButton: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let seconds = link.secondsUntilResend(now: context.date)
      Button {
        Task { await link.resendCode() }
      } label: {
        Label(seconds > 0 ? "Renvoyer le code dans \(seconds) s" : "Renvoyer le code", systemImage: "arrow.clockwise")
          .frame(maxWidth: .infinity)
          .touchTarget()
      }
      .buttonStyle(.bordered)
      .disabled(seconds > 0 || link.isWorking)
      .accessibilityLabel(seconds > 0 ? "Renvoyer le code dans \(seconds) secondes" : "Renvoyer le code")
      .accessibilityIdentifier("resendCode")
    }
    .task(id: link.codeSentAt) {
      // Annonce unique quand le renvoi devient possible.
      let wait = link.secondsUntilResend(now: .now)
      guard wait > 0 else { return }
      try? await Task.sleep(for: .seconds(wait))
      guard !Task.isCancelled else { return }
      AccessibilityNotification.Announcement("Vous pouvez renvoyer le code").post()
    }
  }

  // MARK: - Rapprochement et fin

  private var mergingStep: some View {
    VStack(spacing: Space.m) {
      ProgressView()
      Text("Rapprochement de vos listes…")
        .font(.title3.weight(.semibold))
        .foregroundStyle(Palette.ink)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Space.xl)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var doneStep: some View {
    VStack(spacing: Space.m) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 44))
        .foregroundStyle(Palette.accent)
        .accessibilityHidden(true)
      Text(doneTitle)
        .font(TicketFont.title)
        .foregroundStyle(Palette.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      if let doneMessage {
        Text(doneMessage)
          .foregroundStyle(Palette.inkMuted)
          .multilineTextAlignment(.center)
      }
      Button {
        dismiss()
      } label: {
        Text(isWelcomeBack ? "Voir mes listes" : "Continuer").frame(maxWidth: .infinity)
      }
      .prominentButton()
      .accessibilityIdentifier("finishSignIn")
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Space.l)
  }

  private var isWelcomeBack: Bool {
    if case .signedIn = link.outcome { return true }
    return false
  }

  private var doneTitle: String {
    switch link.outcome {
    case .signedIn(let name?, _): "Bon retour, \(name) !"
    case .signedIn(nil, _): "Bon retour !"
    case .linked, nil: "Adresse liée"
    }
  }

  private var doneMessage: String? {
    switch link.outcome {
    case .signedIn(_, let added): Self.addedListsMessage(added)
    case .linked, nil: "Vous pouvez maintenant retrouver vos listes sur un autre appareil."
    }
  }

  /// « Les 2 listes de ce téléphone ont été ajoutées à votre compte. » Rien à rapprocher : pas de phrase.
  static func addedListsMessage(_ count: Int) -> String? {
    switch count {
    case ..<1: nil
    case 1: "La liste de ce téléphone a été ajoutée à votre compte."
    default: "Les \(count) listes de ce téléphone ont été ajoutées à votre compte."
    }
  }

  // MARK: - Outils

  @ViewBuilder private var errorLine: some View {
    if let errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.circle")
        .font(.callout)
        .foregroundStyle(Palette.ink)
        .accessibilityIdentifier("signInError")
    }
  }

  private var errorMessage: String? {
    guard let error = link.error else { return nil }
    let unknownAccount = !link.canLink && AccountLink.isValid(email: link.normalizedEmail)
    return Self.message(for: error, phase: link.phase, unknownAccount: unknownAccount)
  }

  /// Textes de la maquette (écran 4).
  /// `unknownAccount` : adresse bien formée refusée alors qu'on ne peut que se connecter (compte e-mail sans session).
  static func message(for error: AccountLinkError, phase: AccountLinkPhase, unknownAccount: Bool) -> String {
    switch error {
    case .invalidEmail:
      unknownAccount ? "Aucun compte n'utilise cette adresse." : "Cette adresse ne semble pas valide."
    case .invalidCode: "Ce code ne correspond pas. Vérifiez le dernier e-mail reçu."
    case .expiredCode: "Ce code a expiré. Demandez-en un nouveau."
    case .rateLimited:
      phase == .enterCode
        ? "Trop d'essais. Patientez une minute avant de réessayer."
        : "Trop de codes demandés. Réessayez dans 1 min."
    case .offline: "Il faut du réseau pour recevoir un code."
    case .unknown: "Une erreur est survenue. Réessayez dans un instant."
    }
  }

  private func field(label: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkMuted).accessibilityHidden(true)
      content()
        .font(.body)
        .padding(.horizontal, Space.s)
        .frame(minHeight: 48)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: TicketMetrics.radius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: TicketMetrics.radius, style: .continuous)
            .strokeBorder(Palette.paperEdge, lineWidth: 1)
        }
        .accessibilityLabel(label)
    }
  }
}

/// Code à 6 chiffres : un seul champ `oneTimeCode` (iOS propose le code reçu dans Mail), affiché en cases. Les cases
/// sont décoratives ; VoiceOver lit « Code à 6 chiffres, 3 chiffres saisis sur 6 ».
struct CodeEntryField: View {
  @Binding var code: String
  let length: Int
  let hasError: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ZStack {
      HStack(spacing: typeSize.isAccessibilitySize ? 4 : 8) {
        ForEach(0..<length, id: \.self) { index in
          cell(index)
        }
      }
      .accessibilityHidden(true)
      TextField("", text: $code)
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        // Le texte saisi s'affiche dans les cases.
        .foregroundStyle(.clear)
        .tint(.clear)
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityLabel("Code à \(length) chiffres")
        .accessibilityValue("\(code.count) chiffres saisis sur \(length)")
        .accessibilityIdentifier("codeField")
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
  }

  private func cell(_ index: Int) -> some View {
    let digits = Array(code)
    let isCurrent = index == digits.count && !hasError
    let shape = RoundedRectangle(cornerRadius: TicketMetrics.radius, style: .continuous)
    return Text(index < digits.count ? String(digits[index]) : " ")
      .font(.system(.title2, design: .monospaced).weight(.bold))
      .foregroundStyle(Palette.ink)
      .frame(maxWidth: typeSize.isAccessibilitySize ? 44 : 38)
      .frame(minHeight: typeSize.isAccessibilitySize ? 60 : 52)
      .background(Palette.paper, in: shape)
      .overlay {
        shape.strokeBorder(
          isCurrent ? Palette.accent : Palette.paperEdge,
          lineWidth: isCurrent || contrast == .increased ? 2 : 1)
      }
  }
}
