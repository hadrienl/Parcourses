#!/usr/bin/env bash
# Déploie l'Edge Function send-invitation sur le projet Supabase hébergé, avec ses secrets (#87, lot 87.7).
#
# À lancer par l'utilisateur, depuis la racine du dépôt (jamais par un agent) :
#   scripts/deploy-send-invitation.sh --dry-run   # ce qui serait fait, sans rien envoyer
#   scripts/deploy-send-invitation.sh
#
# Lit ~/.config/parcourses/supabase.env (ou PARCOURSES_SUPABASE_ENV), qui doit définir SUPABASE_PROJECT_REF et
# RESEND_API_KEY ; la CLI doit être connectée (`supabase login`, ou SUPABASE_ACCESS_TOKEN dans ce fichier).
# Aucun secret n'est affiché ni passé en argument (ps) : ils partent par un fichier temporaire en 600, effacé à la fin.
#
# Secrets posés sur la fonction :
#   RESEND_API_KEY        envoi par l'API Resend ;
#   INVITATION_FROM       « Parcourses <noreply@parcourses.hadrien.eu> » (ou INVITATION_FROM du fichier) ;
#   INVITATION_BASE_URL   https://parcourses.hadrien.eu/i/ si la page répond déjà (site/, GitHub Pages), sinon absent :
#                         les liens restent en parcourses://invitation#<jeton>. --scheme-links force ce second cas.
# verify_jwt = false vient de supabase/config.toml ([functions.send-invitation]) et est répété ici (--no-verify-jwt) :
# PostgREST vérifie le JWT de l'utilisateur, la fonction n'a aucun droit de plus que lui.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="${PARCOURSES_SUPABASE_ENV:-$HOME/.config/parcourses/supabase.env}"
SITE="https://parcourses.hadrien.eu"
DRY_RUN=0
SCHEME_LINKS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --scheme-links) SCHEME_LINKS=1 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done

command -v supabase >/dev/null || { echo "CLI supabase introuvable." >&2; exit 2; }
[ -r "$ENV_FILE" ] || { echo "Fichier introuvable : $ENV_FILE" >&2; exit 2; }
# Chargé sans export : seul SUPABASE_ACCESS_TOKEN (pour la CLI) part dans l'environnement des commandes.
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then export SUPABASE_ACCESS_TOKEN; fi
: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF manque dans $ENV_FILE}"
: "${RESEND_API_KEY:?RESEND_API_KEY manque dans $ENV_FILE}"
case "$SUPABASE_PROJECT_REF" in *[!a-z0-9]*) echo "SUPABASE_PROJECT_REF invalide." >&2; exit 2 ;; esac
FROM="${INVITATION_FROM:-Parcourses <noreply@parcourses.hadrien.eu>}"
case "$FROM" in *"'"*|*$'\n'*) echo "INVITATION_FROM ne doit contenir ni apostrophe droite ni saut de ligne." >&2; exit 2 ;; esac
case "$RESEND_API_KEY" in *"'"*|*$'\n'*|*' '*) echo "RESEND_API_KEY a un caractère inattendu." >&2; exit 2 ;; esac

# INVITATION_BASE_URL : posé si la page répond ; retiré seulement sur demande (--scheme-links). Une page injoignable
# (réseau passager) laisse la valeur en place, sans la retirer en silence.
BASE_URL=""
UNSET_BASE=0
if [ "$SCHEME_LINKS" -eq 1 ]; then
  UNSET_BASE=1
elif curl -fsS -m 10 -o /dev/null "$SITE/i/" && curl -fsS -m 10 -o /dev/null "$SITE/.well-known/apple-app-site-association"; then
  BASE_URL="$SITE/i/"
else
  echo "La page $SITE/i/ ne répond pas : INVITATION_BASE_URL n'est pas modifié (relancer une fois le site publié)."
fi

echo "Projet : $SUPABASE_PROJECT_REF"
if [ -n "$BASE_URL" ]; then base_note="$BASE_URL"; elif [ "$UNSET_BASE" -eq 1 ]; then base_note="retiré (liens parcourses://)"; else base_note="inchangé"; fi
echo "Secrets : RESEND_API_KEY (non affiché), INVITATION_FROM = $FROM, INVITATION_BASE_URL = $base_note"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "--dry-run : rien n'est envoyé."
  if [ "$UNSET_BASE" -eq 1 ]; then echo "  supabase secrets unset --project-ref $SUPABASE_PROJECT_REF INVITATION_BASE_URL"; fi
  echo "  supabase secrets set --project-ref $SUPABASE_PROJECT_REF --env-file <fichier temporaire>"
  echo "  supabase functions deploy send-invitation --project-ref $SUPABASE_PROJECT_REF --no-verify-jwt"
  exit 0
fi

secrets="$(mktemp)"
chmod 600 "$secrets"
trap 'rm -f "$secrets"' EXIT
{
  # Guillemets simples : ni $ ni \ ne sont interprétés par le lecteur du fichier (godotenv).
  printf "RESEND_API_KEY='%s'\n" "$RESEND_API_KEY"
  printf "INVITATION_FROM='%s'\n" "$FROM"
  if [ -n "$BASE_URL" ]; then printf "INVITATION_BASE_URL='%s'\n" "$BASE_URL"; fi
} >"$secrets"
if [ "$UNSET_BASE" -eq 1 ]; then
  supabase secrets unset --project-ref "$SUPABASE_PROJECT_REF" INVITATION_BASE_URL
fi
supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" --env-file "$secrets"
supabase functions deploy send-invitation --project-ref "$SUPABASE_PROJECT_REF" --no-verify-jwt

# Vérification sans compte : la fonction répond 405 à un GET (seul POST est accepté), 401 à un POST sans JWT.
url="https://$SUPABASE_PROJECT_REF.supabase.co/functions/v1/send-invitation"
get=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$url" || true)
post=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$url" -d '{}' || true)
echo "Vérification : GET $get (attendu 405), POST sans JWT $post (attendu 401)."
if [ "$get" != 405 ] || [ "$post" != 401 ]; then echo "La fonction ne répond pas comme prévu." >&2; exit 1; fi
echo "send-invitation déployée. Test complet : inviter une adresse depuis l'app (compte e-mail), l'e-mail part de $FROM."
