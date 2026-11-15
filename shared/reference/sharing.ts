// Référence des décisions du partage (#87, lots 87.4 et 87.6) : fonctions pures que les deux apps
// reprennent sous le nom SharingDecisions, vérifiées par les vecteurs de test-vectors/sharing/.

const TOKEN = /^[A-Za-z0-9_-]{43}$/;

// Jeton d'un lien d'invitation : schéma de l'app, ou https sur l'hôte configuré (87.7, Q2).
export function parseInvitationLink(
  input: { url: string; httpsHost: string | null },
): string | null {
  const hash = input.url.indexOf("#");
  if (hash < 0) return null;
  const base = input.url.slice(0, hash);
  const token = input.url.slice(hash + 1);
  if (!TOKEN.test(token)) return null;
  if (base === "parcourses://invitation") return token;
  if (input.httpsHost === null) return null;
  const prefix = "https://";
  if (!base.toLowerCase().startsWith(prefix)) return null;
  const rest = base.slice(prefix.length);
  const slash = rest.indexOf("/");
  if (slash < 0) return null;
  const host = rest.slice(0, slash);
  const path = rest.slice(slash);
  return host.toLowerCase() === input.httpsHost.toLowerCase() && path === "/i/" ? token : null;
}

export type Role = "owner" | "editor" | "viewer";

export function roleCapabilities(input: { role: Role }) {
  const owner = input.role === "owner";
  const writer = owner || input.role === "editor";
  return {
    canEditItems: writer,
    canShop: writer,
    canShare: owner,
    canManageMembers: owner,
    canLeave: !owner,
    canRenameList: owner,
    canDeleteList: owner,
  };
}

const INVITE_ERRORS: Record<string, string> = {
  invalid_email: "invalidEmail",
  self_invitation: "selfInvitation",
  already_member: "alreadyMember",
  list_full: "listFull",
  daily_limit: "dailyLimit",
  pending_limit: "pendingLimit",
  recipient_limit: "recipientLimit",
  "not allowed": "notAllowed",
  unauthorized: "signInRequired",
};

export function inviteErrorKind(input: { error: string | null }): string {
  if (input.error === null) return "offline";
  return INVITE_ERRORS[input.error] ?? "unknown";
}

export function invitationCardState(input: { status: string; emailMatches: boolean }): string {
  switch (input.status) {
    case "pending":
      return input.emailMatches ? "acceptable" : "otherAddress";
    case "member":
      return "alreadyMember";
    case "used":
      return "used";
    case "expired":
      return "expired";
    case "rate_limited":
      return "rateLimited";
    default:
      return "invalid";
  }
}

export function acceptOutcome(input: { status: string }): string {
  switch (input.status) {
    case "accepted":
      return "joined";
    case "member":
      return "alreadyMember";
    case "used":
      return "used";
    case "expired":
      return "expired";
    case "rate_limited":
      return "rateLimited";
    default:
      return "invalid";
  }
}

export function signalActions(input: { kind: string; sharingSheetOpen: boolean }): string[] {
  const actions: string[] = [];
  if (input.kind === "invitations") {
    actions.push("reloadInvitations");
  } else {
    actions.push("pull");
  }
  if ((input.kind === "members" || input.kind === "invitations") && input.sharingSheetOpen) {
    actions.push("reloadSharing");
  }
  return actions.sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
}

export function memberInitial(input: { displayName: string | null }): string {
  const first = [...(input.displayName ?? "").trim()][0];
  return first === undefined ? "?" : first.toLocaleUpperCase("fr");
}

export function itemAuthorMark(input: {
  updatedBy: string | null;
  me: string;
  shared: boolean;
  members: { userId: string; displayName: string | null }[];
}): string | null {
  if (!input.shared || input.updatedBy === null || input.updatedBy === input.me) return null;
  const author = input.members.find((m) => m.userId === input.updatedBy);
  return author ? memberInitial({ displayName: author.displayName }) : null;
}
