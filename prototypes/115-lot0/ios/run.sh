#!/usr/bin/env bash
# Prototype iOS du lot 0 de #115 : build, enregistrements des scénarios de mesure, tests des gestes.
# Tout passe sous le jeton partagé, avec au moins 6 Gio libres :
#   prototypes/115-lot0/ios/run.sh <dossier de sortie>
# Le simulateur dédié est supprimé à la fin (place disque) ; `PROTO_SKIP_LANE=1` saute les tests des gestes.
# Sortie : vidéos `sort-*.mov`, `fling.mov`, `lane.mov`, captures `shots/*.png`, journal de test.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=${1:?usage : run.sh <dossier de sortie>}
mkdir -p "$out/shots"
out=$(cd "$out" && pwd)

if [[ "${PROTO_LOCKED:-}" != 1 ]]; then
  # Au moins 6 Gio, même si l'environnement exporte un seuil plus bas.
  min_kb=${PARCOURSES_BUILD_MIN_FREE_KB:-0}
  ((min_kb < 6291456)) && min_kb=6291456
  PROTO_LOCKED=1 PARCOURSES_BUILD_MIN_FREE_KB=$min_kb \
    exec "$repo/scripts/build-lock.sh" proto-115-ios "$0" "$out"
fi

device_name="Proto115 iPhone 17 Pro"
runtime=com.apple.CoreSimulator.SimRuntime.iOS-26-5
udid=$(xcrun simctl list devices -j | /usr/bin/python3 -c "
import json, sys
for rt, devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d['name'] == '$device_name' and d['isAvailable']:
            print(d['udid']); sys.exit()
")
if [[ -z "$udid" ]]; then
  udid=$(xcrun simctl create "$device_name" "iPhone 17 Pro" "$runtime")
fi
echo "simulateur : $udid"

derived="$out/derived"
results="$out/tests.xcresult"
rm -rf "$results"
cleanup() {
  [[ -n "${recorder:-}" ]] && kill -INT "$recorder" 2>/dev/null || true
  rm -rf "$results" "$derived"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$here"
xcodegen generate --quiet
xcodebuild build-for-testing -project ThreadProto.xcodeproj -scheme ThreadProto \
  -destination "id=$udid" -derivedDataPath "$derived" -quiet >"$out/build.log" 2>&1 \
  || { grep -E "error:" "$out/build.log" | head -20; exit 1; }

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" >/dev/null
app=$(find "$derived/Build/Products" -name ThreadProto.app -maxdepth 2 | head -1)
xcrun simctl install "$udid" "$app"
bundle=app.parcourses.proto.thread

record() { # nom, secondes, arguments…
  local name=$1 seconds=$2
  shift 2
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/$name.mov" >/dev/null 2>&1 &
  recorder=$!
  sleep 1.5
  xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
  sleep "$seconds"
  kill -INT "$recorder"
  wait "$recorder" || true
  recorder=
}

# Enregistrements : B tel que conçu (ressort vers la position finale), B compensé (« follow »), A (liste sans
# animation), lancer. `PROTO_SKIP_LANE=1` saute les tests des gestes.
record sort-spring 19 -scenario sort -trackAnim spring
record sort-none 19 -scenario sort -trackAnim none
record sort-follow 19 -scenario sort -trackAnim follow -trackResponse 0.3
record sort-follow-035 19 -scenario sort -trackAnim follow -trackResponse 0.35
record sort-a 19 -scenario sort -trackAnim none -listAnim none
record fling 14 -scenario fling
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
[[ "${PROTO_SKIP_LANE:-}" == 1 ]] && exit 0

# Tests des gestes, enregistrés aussi (invariance de la gouttière image par image).
xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/lane.mov" >/dev/null 2>&1 &
recorder=$!
set +e
TEST_RUNNER_PROTO_SHOTS="$out/shots" xcodebuild test-without-building -project ThreadProto.xcodeproj \
  -scheme ThreadProto -destination "id=$udid" -derivedDataPath "$derived" -resultBundlePath "$results" \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 400 >"$out/test.log" 2>&1
status=$?
set -e
kill -INT "$recorder"
wait "$recorder" || true
grep -E "Test Case|error:|XCTAssert|failed|passed" "$out/test.log" | tail -30
exit $status
