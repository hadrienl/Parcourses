#!/usr/bin/env bash
# Prototype Android du lot 0 de #115 : mesure du trait unique (option B) sous `animateItem` et au défilement.
# Copie le test dans `feature/shopping` le temps d'un lancement, ne joue que lui, puis supprime la copie (même en cas
# d'échec). Tout passe sous le jeton partagé, avec au moins 6 Gio libres :
#   prototypes/115-lot0/android/run.sh
# Sortie : tableau des écarts par source et par scénario, tracés des clés de section.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)

if [[ "${PROTO_LOCKED:-}" != 1 ]]; then
  PROTO_LOCKED=1 PARCOURSES_BUILD_MIN_FREE_KB=${PARCOURSES_BUILD_MIN_FREE_KB:-6291456} \
    exec "$repo/scripts/build-lock.sh" proto-115-android "$0" "$@"
fi

export JAVA_HOME="${JAVA_HOME_OVERRIDE:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/Users/hadrien/Library/Android/sdk}"

android="$repo/android"
dest="$android/feature/shopping/src/test/kotlin/fr/parcourses/feature/shopping/proto"
results="$android/feature/shopping/build/test-results/testDebugUnitTest"
cleanup() {
  rm -rf "$dest"
  (cd "$android" && ./gradlew --stop >/dev/null 2>&1) || true
}
trap cleanup EXIT

mkdir -p "$dest"
cp "$here/ThreadTrackProtoTest.kt" "$dest/"
rm -f "$results"/TEST-fr.parcourses.feature.shopping.proto.*.xml

status=0
(cd "$android" && ./gradlew --no-daemon -q -Pkotlin.compiler.execution.strategy=in-process :feature:shopping:testDebugUnitTest --tests '*proto*') || status=$?

xml=$(ls "$results"/TEST-fr.parcourses.feature.shopping.proto.*.xml 2>/dev/null | head -1 || true)
if [[ -z "$xml" ]]; then
  echo "run.sh : pas de rapport de test (statut $status)" >&2
  ((status != 0)) || status=1
  exit "$status"
fi

echo
echo "source | scénario | images | dessins du trait | dessins à la capture | images où un marqueur bouge sans dessin |" \
  "écart marqueurs max (dp) | moyen (dp) | échantillons | images > 7 dp | écart toutes perles max (dp) | moyen (dp) |" \
  "perles déplacées | dont sans onPlaced de la gouttière | dont sans rappel de la source |" \
  "images vérifiées aux pixels | images avec trou | trou max (dp) | dépassement max (dp) | jonction hors perle max (dp)"
grep -h '^P115 ROW' "$xml" | sed 's/^P115 ROW | //'
echo
grep -h '^P115 LAG' "$xml" | sed 's/^P115 LAG | /retards : /' || true
echo
grep -h '^P115 STALE' "$xml" | sed 's/^P115 STALE | /toutes perles : /' || true
echo
grep -h '^P115 KEY' "$xml" | sed 's/^P115 //' || true
# Progression et échecs, pour diagnostiquer un lancement interrompu.
((status == 0)) || grep -h '^P115 DBG' "$xml" | tail -20 || true
grep -h 'Exception\|AssertionError' "$xml" | head -20 || true
exit "$status"
