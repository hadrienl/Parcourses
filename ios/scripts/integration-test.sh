#!/usr/bin/env bash
# Tests d'intégration du gateway contre le Supabase LOCAL (ports 563xx), qui doit être démarré.
# Usage, depuis ios/ : scripts/integration-test.sh
set -euo pipefail

status=$(cd .. && supabase status -o env 2>/dev/null)
value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" <<<"$status"; }
url=$(value API_URL)
key=$(value PUBLISHABLE_KEY)

if [[ "$url" != "http://127.0.0.1:56321" || -z "$key" ]]; then
  echo "Supabase local introuvable (attendu sur 127.0.0.1:56321) : lancer supabase start." >&2
  exit 1
fi

udid=$(scripts/simulator.sh latest)
xcodegen generate --quiet
TEST_RUNNER_PARCOURSES_IT_URL="$url" TEST_RUNNER_PARCOURSES_IT_KEY="$key" \
  xcodebuild test -project Parcourses.xcodeproj -scheme Parcourses -destination "id=$udid" \
  -derivedDataPath DerivedData -only-testing:ParcoursesTests
