#!/usr/bin/env bash
# Sélectionne le dernier Xcode stable du runner. Les bêtas sont exclues (`Xcode_27.3_beta.app` est apparu sur l'image
# xcode-27 du 19/11/2026) : la CI doit compiler avec le SDK des builds livrés, et App Store Connect refuse un build
# fait avec une bêta.
set -euo pipefail
xcode=$(ls -d /Applications/Xcode_*.app | grep -E '/Xcode_[0-9]+(\.[0-9]+)*\.app$' | sort -V | tail -1)
[[ -n "$xcode" ]] || { echo "Aucun Xcode stable dans /Applications" >&2; exit 1; }
sudo xcode-select -s "$xcode"
xcodebuild -version
