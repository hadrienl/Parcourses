#!/usr/bin/env bash
# Renvoie l'UDID d'un iPhone sur le runtime demandé (« 18 » ou « latest »), en le créant au besoin.
set -euo pipefail
want="${1:-latest}"
if [ "$want" = latest ]; then
  runtime=$(xcrun simctl list runtimes -j | jq -r '[.runtimes[]|select(.platform=="iOS" and .isAvailable)]|sort_by(.version|split(".")|map(tonumber))|last|.identifier')
else
  runtime=$(xcrun simctl list runtimes -j | jq -r --arg v "$want" '[.runtimes[]|select(.platform=="iOS" and .isAvailable and (.version|startswith($v+".")))]|sort_by(.version|split(".")|map(tonumber))|last|.identifier // empty')
fi
[ -n "$runtime" ] || { echo "Aucun runtime iOS $want" >&2; exit 1; }
name="Parcourses CI ($runtime)"
udid=$(xcrun simctl list devices -j | jq -r --arg r "$runtime" --arg n "$name" '.devices[$r][]?|select(.name==$n)|.udid' | head -1)
if [ -z "$udid" ]; then
  # Dernier iPhone pris en charge par ce runtime.
  type=$(xcrun simctl list runtimes -j | jq -r --arg r "$runtime" '.runtimes[]|select(.identifier==$r)|[.supportedDeviceTypes[]|select(.productFamily=="iPhone")]|last|.identifier')
  udid=$(xcrun simctl create "$name" "$type" "$runtime")
fi
echo "$udid"
