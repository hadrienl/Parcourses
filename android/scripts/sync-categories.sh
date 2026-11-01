#!/usr/bin/env bash
# Copie le dictionnaire des catégories de shared/categories/ vers les ressources de :core:categorizer.
# Avec --check, n'écrit rien et échoue si la copie embarquée diffère de la source (utilisé en CI).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/shared/categories"
dst="$root/android/core/categorizer/src/main/resources/fr/parcourses/core/categorizer"
files=(categories.json normalization.json keywords.fr.json)
if [[ "${1:-}" == "--check" ]]; then
  status=0
  for f in "${files[@]}"; do
    cmp -s "$src/$f" "$dst/$f" || { echo "::error::$f diffère de shared/categories (lancer android/scripts/sync-categories.sh)"; status=1; }
  done
  exit $status
fi
for f in "${files[@]}"; do cp "$src/$f" "$dst/$f"; done
