# Prototype iOS du lot 0 (#115)

App isolée (`ThreadProto`, XcodeGen, iOS 18), hors de l'app Parcourses. Elle reproduit l'option B :
- `ThreadTrack` : le trait est dessiné une fois, en fond de la `List`, à partir des positions publiées par les perles ;
- `ThreadGutter` : la perle est placée dans un cadre de hauteur nulle, aligné sur `.threadMarker` ;
- `RowLane` : le couloir est dans le label d'un `Button`, avec le glisser maison, le style de bouton et le `contextMenu`.

## Lancer

```sh
prototypes/115-lot0/ios/run.sh <dossier de sortie>        # sous scripts/build-lock.sh, ≥ 6 Gio libres
python3 -I prototypes/115-lot0/ios/analyze.py <sortie>/sort-follow.mov [--series]
```

`run.sh` génère le projet, construit l'app et les tests UI dans `<sortie>/derived`, puis :
- enregistre les scénarios de mesure avec `simctl io recordVideo` ;
- lance les tests des gestes ;
- supprime les DerivedData et le `.xcresult`.

Simulateur dédié : « Proto115 iPhone 17 Pro », sous iOS 26.5, le runtime de la CI.

## Mesure

Les couleurs franches permettent de lire chaque image de l'enregistrement :
- le trait parcouru est rouge, le trait à parcourir bleu ;
- une **sonde** copie le trait 11 pt à côté, où aucune perle ne la cache ;
- les perles première, suivante et dernière ont chacune leur couleur ;
- un témoin en haut à droite indique la phase en cours.

`analyze.py` lit trois colonnes de pixels par image avec ffmpeg. Il en tire :
- l'écart entre chaque bout du trait et sa perle (première, suivante, dernière) ;
- l'écart entre les bouts du trait et les perles extrêmes : un trait qui dépasse ou une perle hors du trait ;
- le plus grand trou.

Les résultats sont dans le compte rendu de la PR et au §7 de `docs/design/115-fil-immobile.md`.
