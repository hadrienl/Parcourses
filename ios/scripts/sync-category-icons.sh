#!/usr/bin/env bash
# Copie les icônes de rayon de design/icons/categories/ (source de vérité, #6) dans Assets.xcassets, en images
# vectorielles « template » : `Image("cat.<id>")`, teintées par la couleur du rayon.
# Le trait `currentColor` devient noir : le rendu template ne garde que l'opacité.
# Avec --check, n'écrit rien et échoue si le catalogue diffère de la source (utilisé en CI).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/design/icons/categories"
dst="$root/ios/Parcourses/Assets.xcassets/Categories"
contents='{
  "images" : [
    {
      "filename" : "%s.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
'
render() { sed -e 's/currentColor/#000000/g' -e 's/ role="img"//' -e 's/ aria-label="[^"]*"//' "$1"; }
check=0
[[ "${1:-}" == "--check" ]] && check=1
status=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Categories"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "properties" : {\n    "provides-namespace" : false\n  }\n}\n' >"$tmp/Categories/Contents.json"
for svg in "$src"/*.svg; do
  id="$(basename "$svg" .svg)"
  set="$tmp/Categories/cat.$id.imageset"
  mkdir -p "$set"
  render "$svg" >"$set/$id.svg"
  # shellcheck disable=SC2059
  printf "$contents" "$id" >"$set/Contents.json"
done
if [[ $check == 1 ]]; then
  diff -r "$tmp/Categories" "$dst" >/dev/null || {
    echo "::error::Assets.xcassets/Categories diffère de design/icons/categories (lancer ios/scripts/sync-category-icons.sh)"
    status=1
  }
  exit $status
fi
rm -rf "$dst"
cp -R "$tmp/Categories" "$dst"
