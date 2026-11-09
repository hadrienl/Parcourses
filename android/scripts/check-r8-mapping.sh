#!/usr/bin/env bash
# Vérifie, après `assembleRelease`, que R8 n'a pas renommé les classes dont le nom est lu à l'exécution (A12).
# Les règles sont dans core/data/consumer-rules.pro et core/network/consumer-rules.pro.
set -euo pipefail

cd "$(dirname "$0")/.."
mapping="${1:-app/build/outputs/mapping/release/mapping.txt}"
[[ -f "$mapping" ]] || { echo "Mapping R8 introuvable : $mapping (lancer assembleRelease)" >&2; exit 1; }

# Classes attendues sous leur nom d'origine, avec la raison.
kept=(
  "fr.parcourses.core.data.sync.ListSyncWorker"                         # nom enregistré par WorkManager
  "com.google.crypto.tink.shaded.protobuf.InvalidProtocolBufferException" # AeadSource.isCorruptionProof
)

status=0
for class in "${kept[@]}"; do
  line=$(grep -F -- "$class -> " "$mapping" | grep -v '^ ' | head -n 1 || true)
  if [[ -z "$line" ]]; then
    echo "Absente du mapping : $class" >&2
    status=1
  elif [[ "$line" != "$class -> $class:" ]]; then
    echo "Renommée par R8 : $line" >&2
    status=1
  fi
done
[[ $status -eq 0 ]] && echo "Noms gardés par R8 : ${#kept[@]}/${#kept[@]}"
exit $status
