# #115, lot 0 : prototype Android du trait unique (option B)

Mesure, image par image, l'écart entre le trait dessiné une seule fois par un `drawBehind` posé sur la `LazyColumn`
et les perles réelles, pendant un tri, des départs et un défilement rapide. Conception :
[`docs/design/115-fil-immobile.md`](../../../docs/design/115-fil-immobile.md), §4 B et §7.

## Lancer

```sh
prototypes/115-lot0/android/run.sh
```

Le script prend le jeton de build partagé (6 Gio libres au moins), copie `ThreadTrackProtoTest.kt` dans
`android/feature/shopping/src/test/kotlin/fr/parcourses/feature/shopping/proto/`, ne joue que
`:feature:shopping:testDebugUnitTest --tests '*proto*'` (sans démon), puis supprime la copie, même en cas d'échec.
Il imprime le tableau des écarts tiré du rapport JUnit.

## Montage

- `LazyColumn` de 20 lignes de 56 dp (100 pour le défilement), `animateItem` avec `TicketMotion.reorder` et
  `TicketMotion.fade`. Chaque ligne a une gouttière de 28 dp qui porte une perle (disque de 14 dp).
- `ThreadTrackState` : trois marqueurs (premier, suivant, dernier), lus en phase de dessin par un `drawBehind` sur la
  `LazyColumn`. La liste est dans un calque à elle (`graphicsLayer`), comme sous un hôte de navigation : son dessin
  n'est refait que s'il est invalidé.
- Sources comparées : `onPlaced`, `onGloballyPositioned`, `onLayoutRectChanged(0, 0)`,
  `onLayoutRectChanged` par défaut (0, 64 ms), et des coordonnées gardées puis lues au moment du dessin.
- Pipeline : Robolectric en graphismes natifs avec les vrais parcours de dessin (`ShadowView.setUseRealDrawTraversals`)
  et un Choreographer en pause. Une image = `advanceTimeByFrame` (animations Compose) puis 16 ms d'horloge Android
  (vsync : mise en page, rappels, dessin). La capture recopie la dernière image rendue.
- Position réelle : `positionInRoot` de la gouttière à la fin de l'image (transformations de calque comprises).
  Vérification aux pixels : colonne du trait dans la capture (trou, dépassement, jonction hors de la perle suivante).

## Colonnes du tableau

Images mesurées ; dessins du trait pendant les images (et pendant les captures, qui doivent être 0) ; images où un
marqueur bouge sans que le trait soit redessiné ; écart trait / perle des marqueurs visibles (max, moyen, nombre
d'échantillons, images au-delà de 7 dp) ; écart entre la valeur publiée et la perle pour toutes les perles visibles ;
perles déplacées, dont sans `onPlaced` de la gouttière et sans rappel de la source ; contrôle aux pixels.

## Résultats (2026-11-17, Compose BOM 2026.09.00, Robolectric 4.17, SDK 35)

- `onPlaced` (qui lit `positionInRoot`), `onGloballyPositioned` et `onLayoutRectChanged(0, 0)` : 0,00 dp d'écart sur
  les marqueurs, dans toutes les images du tri, des départs et des deux défilements. Aucun retard d'une image : la
  valeur écrite pendant la mise en page est celle que lit le dessin de la même image. Aucun trou aux pixels.
- `onLayoutRectChanged` par défaut (rebond de 64 ms) : inutilisable, valeurs reçues trop tard.
- Coordonnées lues au dessin, sans état : exactes, mais le `drawBehind` n'est jamais redessiné pendant un défilement
  (0 dessin sur 66 et 100 images), d'où un trait figé jusqu'à 576 dp à côté de sa perle.
- `onPlaced` d'une gouttière n'est pas rappelé quand seul l'élément parent est replacé, sauf si son rappel lit les
  coordonnées (`coordinatesAccessedDuringPlacement` : Compose replace alors le nœud à chaque déplacement d'un ancêtre).
- Une ligne qui sort de l'écran garde des coordonnées attachées mais figées : il faut trancher par
  `layoutInfo.visibleItemsInfo`, comme prévu au §4.
- Clé préfixée par section : fondu de sortie sur place puis fondu d'entrée à la nouvelle place, sans glissement.
  Clé partagée : la ligne glisse de 210 dp.
- Non mesuré : l'étirement de bord. C'est un effet de rendu, sans effet sur la mise en page ni sur la sémantique.
