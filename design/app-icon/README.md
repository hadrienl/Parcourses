# Icône Parcourses

Direction retenue : panier B « d’un trait », palette D « ocre & encre ».

Source vectorielle : `parcourses-ocre-encre.svg`, contours extraits du PNG retenu puis vectorisés avec Potrace (tolérance d’optimisation : 0,15 pixel). Cette version remplace le premier dessin approximatif de l’anse. Aplats dans la palette cible, fond carré plein, sans masque de coins. Rendu vérifié avec Quick Look. Le viewBox conserve les coordonnées du PNG (1254 × 1254).

Exploration finalisée : `parcourses-ocre-encre-v1.png`. Ce PNG original et le SVG sont les deux sources conservées dans le projet. Les assets des apps sont dérivés du SVG pour garder les contours validés et les couleurs unies.

## Intégration mobile

- iOS : `ios/Parcourses/Assets.xcassets/AppIcon.appiconset`, PNG universel 1024 × 1024 sans canal alpha, référencé par `ios/project.yml`.
- Android : icônes adaptatives standard et ronde (API 26+), fond ocre séparé, premier plan vectoriel réduit à 72 % pour respecter la zone sûre des masques. Variante monochrome pour les icônes thématiques Android 13+, PNG de 48 à 192 px pour les cinq densités.

Régénérer avec `python3 scripts/generate-app-icons.py` depuis la racine (macOS, Quick Look, ffmpeg et sips). Si Quick Look doit être lancé séparément :

```sh
qlmanage -t -s 1024 -o /private/tmp "$PWD/design/app-icon/parcourses-ocre-encre.svg"
python3 scripts/generate-app-icons.py --rendered /private/tmp/parcourses-ocre-encre.svg.png
```

Palette cible : ocre `#DDB454`, encre `#202A43`, ivoire `#FFF7E8`. Les couleurs du rendu généré peuvent varier légèrement.

Génération : outil intégré imagegen, à partir de la planche de palettes.

Prompt final : conserver exactement le panier B de la variante D, contour encre épais et arrondi, anse ouverte formant un trajet terminé par un point ivoire ; adoucir l’ocre ; produire une icône carrée seule, fond plein jusqu’aux bords, sans texte ni masque de coins, avec des marges adaptées aux masques iOS et Android ; demander des couleurs unies, sans texture ni ombre.
