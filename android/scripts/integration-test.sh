#!/usr/bin/env bash
# Tests d'intégration contre le Supabase LOCAL (ports 563xx), qui doit être démarré.
# Usage, depuis android/ : scripts/integration-test.sh
set -euo pipefail

status=$(cd .. && supabase status -o env 2>/dev/null)
value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" <<<"$status"; }
url=$(value API_URL)
key=$(value PUBLISHABLE_KEY)

if [[ "$url" != "http://127.0.0.1:56321" || -z "$key" ]]; then
  echo "Supabase local introuvable (attendu sur 127.0.0.1:56321) : lancer supabase start." >&2
  exit 1
fi

# --rerun : les variables d'environnement ne sont pas des entrées de la tâche de test.
# Passerelle (A5), synchronisation complète des listes (A6), puis visite complète du mode courses (A8) : coches,
# fin, envoi, calcul du graphe (docker exec sur la base du Supabase local) et lecture de l'instantané.
# Contre le Supabase local uniquement.
PARCOURSES_IT_URL="$url" PARCOURSES_IT_KEY="$key" \
  ./gradlew :core:network:testDebugUnitTest --tests '*SupabaseGatewayIntegrationTest' \
  :core:data:testDebugUnitTest --tests '*SyncIntegrationTest' \
  :feature:shopping:testDebugUnitTest --tests '*ShoppingIntegrationTest' --rerun "$@"
