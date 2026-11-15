#!/usr/bin/env bash
# Hôte des liens d'invitation (#87, lot 87.7) : réglages résolus par Xcode, avec l'hôte par défaut puis un hôte vide.
#   - défaut : Info.plist et domaine associé sur parcourses.hadrien.eu ;
#   - vide : aucun hôte https, domaine associé sur l'hôte réservé invitation.invalid (jamais `applinks:` seul).
# Usage, depuis ios/ après `xcodegen generate` : scripts/check-invitation-host.sh
set -euo pipefail

settings() {
  xcodebuild -showBuildSettings -project Parcourses.xcodeproj -target Parcourses -configuration "$1" "${@:2}" 2>/dev/null
}
value() { sed -n "s/^ *$1 = \(.*\)$/\1/p" <<<"$2" | head -1; }
failures=0
expect() {
  if [[ "$2" != "$3" ]]; then
    echo "✗ $1 : attendu « $3 », trouvé « $2 »" >&2
    failures=$((failures + 1))
  fi
}

grep -q '<string>applinks:$(PARCOURSES_APPLINKS_HOST)</string>' Parcourses/Parcourses.entitlements ||
  { echo "✗ Parcourses.entitlements : applinks:\$(PARCOURSES_APPLINKS_HOST) absent" >&2; failures=$((failures + 1)); }
for configuration in Debug Release; do
  default=$(settings "$configuration")
  expect "$configuration, hôte par défaut" "$(value PARCOURSES_INVITATION_HOST "$default")" parcourses.hadrien.eu
  expect "$configuration, domaine associé par défaut" "$(value PARCOURSES_APPLINKS_HOST "$default")" parcourses.hadrien.eu
  empty=$(settings "$configuration" PARCOURSES_INVITATION_HOST=)
  expect "$configuration, hôte vide" "$(value PARCOURSES_INVITATION_HOST "$empty")" ""
  expect "$configuration, domaine associé sans hôte" "$(value PARCOURSES_APPLINKS_HOST "$empty")" invitation.invalid
done
((failures == 0)) || exit 1
echo "Hôte des invitations conforme : parcourses.hadrien.eu par défaut, invitation.invalid sans hôte."
