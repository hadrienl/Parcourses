#!/usr/bin/env bash
# Jeton de build partagé entre les sessions (#87) : un seul build ou test d'app à la fois sur la machine, et au moins
# 3,5 Go libres avant de commencer. Enveloppe une commande : le jeton est pris (mkdir atomique), la commande tourne,
# le jeton est rendu à la sortie, même en cas d'échec. Un jeton dont le processus a disparu est repris.
#
# Usage : scripts/build-lock.sh <qui> <commande> [arguments…]
#   scripts/build-lock.sh ios-87.3 ios/scripts/integration-test.sh
# Variables : PARCOURSES_BUILD_LOCK (défaut /tmp/parcourses-build.lock), PARCOURSES_BUILD_MIN_FREE_KB (3,5 Gio),
# PARCOURSES_BUILD_WAIT_S (attente maximale du jeton puis de l'espace, 3600 s).
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage : $0 <qui> <commande> [arguments…]" >&2
  exit 64
fi
who=$1
shift
lock=${PARCOURSES_BUILD_LOCK:-/tmp/parcourses-build.lock}
min_free_kb=${PARCOURSES_BUILD_MIN_FREE_KB:-3670016}
wait_s=${PARCOURSES_BUILD_WAIT_S:-3600}
deadline=$((SECONDS + wait_s))

free_kb() { df -k / | awk 'NR == 2 { print $4 }'; }

until mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/owner" 2>/dev/null || true)
  pid=${holder%% *}
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
    echo "build-lock : jeton abandonné par « $holder », repris" >&2
    rm -rf "$lock"
    continue
  fi
  if ((SECONDS >= deadline)); then
    echo "build-lock : jeton toujours tenu par « $holder » après ${wait_s} s" >&2
    exit 75
  fi
  echo "build-lock : en attente du jeton (tenu par « $holder »)" >&2
  sleep 20
done
echo "$$ $who $(date '+%H:%M:%S')" >"$lock/owner"
trap 'rm -rf "$lock"' EXIT

until (($(free_kb) >= min_free_kb)); do
  if ((SECONDS >= deadline)); then
    echo "build-lock : $(($(free_kb) / 1024)) Mio libres, il en faut $((min_free_kb / 1024))" >&2
    exit 75
  fi
  echo "build-lock : $(($(free_kb) / 1024)) Mio libres, attente de $((min_free_kb / 1024))" >&2
  sleep 30
done

echo "build-lock : jeton pris par $who ($(($(free_kb) / 1024)) Mio libres)" >&2
"$@"
