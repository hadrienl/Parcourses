# #115 : fil du ticket immobile

> Conception **validée le 2026-11-17 : option B**, décisions au §8. Base de lecture : `main` (4d0f5fd) et la branche de la PR #112
> (`feat/item-quantity-edit`), qui a déjà rendu l'appui long de l'écran Liste conforme.
> Maquette animée : [`design/fil-immobile.html`](../../design/fil-immobile.html) (« Aujourd'hui » et « Proposé » côte
> à côte : glisser, coche, tri, appui long ; ralenti et mouvement réduit).

## 1. La règle

> « Le trait ne doit jamais bouger, sinon ça casse la ligne. »

Le **fil** du ticket regroupe le trait vertical, sa partie parcourue (accent), ses perles d'article et ses nœuds de
rayon. Il reste **immobile** en toutes circonstances : glisser (supprimer, « Pas trouvé », cocher sur Android), coche,
réordonnancement du mode courses, insertion et retrait d'une ligne, changement de hauteur d'une ligne, appui long et
menu contextuel. **Seuls la case, le libellé et la quantité bougent.**

Ce que « immobile » veut dire, précisément :

- le trait ne change **jamais** d'abscisse et n'est **jamais** interrompu, recouvert ou atténué par morceaux ;
- une perle ou un nœud ne quitte jamais le trait. Quand l'ordre change, il peut **glisser le long du trait** avec sa
  ligne (abscisse fixe) : c'est le seul déplacement admis, et il est vertical (décision D1) ;
- les bouts du trait suivent le premier et le dernier marqueur : le trait s'allonge ou se raccourcit par un bout, il
  ne se déplace pas (décision D6) ;
- la partie parcourue continue de « couler » le long du trait quand l'article suivant change : c'est une couleur qui
  avance, pas un mouvement du trait.

## 2. Constat

### 2.1 iOS (SwiftUI, `List`)

| Mécanisme | Où | Effet sur le fil |
| --- | --- | --- |
| `ThreadRow` dessine les deux tronçons et la perle dans le fond (`backgroundPreferenceValue`) **du contenu** de chaque ligne ; la perle se place sur l'ancre de la case (`threadAnchor()`, `anchorPreference`). | `DesignSystem/TicketThread.swift` ; 3 appels : `ListDetailView` (articles), `ShoppingView` (articles), `AisleLine` (rayons, les deux écrans) | Le fil appartient à la ligne : tout ce qui déplace la ligne déplace son morceau de fil. |
| `.swipeActions` : UIKit fait glisser la `contentView` de la cellule ; seul `listRowBackground` reste. | `ListDetailView` (Supprimer, glisser partiel) ; `ShoppingView` (Pas trouvé, **glisser complet**) ; `ListsView` (hors fil) | Le tronçon et la perle partent avec le contenu. Dessiner le fil dans `listRowBackground` (piste 1 de l'issue) ne suffit pas, sur les deux écrans : la `contentView` glisse **par-dessus** ce fond, donc la case passe sur le fil, et SwiftUI ne peut pas la rogner au bord de la gouttière (le décalage est appliqué par UIKit, hors de l'arbre SwiftUI). En glisser complet, le bouton orange s'étend en plus sur toute la largeur de la cellule et **recouvre la gouttière**. |
| `.contextMenu` sur la ligne du mode courses | `ShoppingView.itemRow` | L'aperçu soulevé est la ligne entière, fil compris : le tronçon se décale et grossit au-dessus du voile. |
| `Button` en `.buttonStyle(.plain)` | `ShoppingView.itemRow` | Au toucher, iOS atténue tout le libellé du bouton, fil compris : le tronçon pâlit le temps de l'appui (à confirmer sur appareil, c'est le comportement documenté du style). |
| Tri : `.animation(Motion.reorder, value: lines.map(\.id))` sur la `List` ; UIKit anime déplacements, insertions, retraits et changements de hauteur. | `ShoppingView` | Chaque tronçon voyage avec sa ligne : la partie parcourue (accent) se déplace par morceaux, les lignes qui entrent ou sortent en fondu laissent un tronçon à demi transparent, les drapeaux « premier / dernier » changent d'un coup pendant que les lignes glissent (bout de trait qui dépasse ou manque). |
| Coche | `CheckBox` (`Motion.check`), `Bead` | Sur place, la coche ne déplace rien. En mode courses, la ligne cochée reste à sa place le temps de `settleDelay` (600 ms, `ShoppingSession.settlingIds`), puis part au panier, et la suivante grandit (`TicketFont.itemNext`) : on retombe dans le cas du tri. |
| Appui long de l'écran Liste | `ItemLine(pressed:)` (PR #112) | Corrigé : seuls la case et le texte s'enfoncent. Nuance : l'ancre de la perle est lue **après** `scaleEffect` ; sur un libellé replié (case alignée sur la première ligne), la perle peut bouger d'une fraction de point pendant l'appui. |
| Fonds | `ticketRow(background:)` : `listRowBackground(Palette.paper)` opaque, ou surlignage d'accent de l'article ajouté | Le surlignage couvre aussi la gouttière. |

### 2.2 Android (Compose, `LazyColumn`)

| Mécanisme | Où | Effet sur le fil |
| --- | --- | --- |
| `Modifier.thread(piece, style)` dessine tronçons et perle en `drawBehind` **de la ligne** ; perle au centre vertical de la ligne (la case y est centrée aussi). | `core/designsystem/Thread.kt` ; 4 usages sur la branche de #112 : `AisleLine`, `ListDetailScreen.ItemRowView`, `ListDetailSharing.ReadOnlyItemRow`, `ShoppingRows.ItemRowContent` | Même constat qu'iOS : le fil appartient à la ligne. |
| `SwipeToDismissBox` (droite : cocher, gauche : Pas trouvé ; fond vide, la ligne revient toujours) | `feature/shopping/ShoppingRows.kt` | `.thread` est dans le **contenu** : le fil glisse avec la ligne, dans les deux sens. |
| `Modifier.animateItem(placement = TicketMotion.reorder, fade in/out)` sur lignes et titres de rayon | `ShoppingScreen.ticketMotion` | Le fil voyage avec chaque élément ; fondus d'entrée et de sortie ; les pointillés (`ThreadStyle.Dashed`, ordre générique ou en apprentissage) repartent à chaque ligne. |
| Même clé (`row.id`) pour une ligne à prendre, introuvable (`notFound`) ou au panier (`basket`) | `ShoppingScreen.kt` (`item(key = row.id)`, `items(rows, key = { it.id })` ×2) | `animateItem` traite le passage d'une section à l'autre comme un **déplacement** : panier déplié, la ligne cochée glisse, perle pleine comprise (`Bead.Checked`), au-delà du bout du fil, traverse « Introuvable » et rejoint le panier ; « Pas trouvé » bascule vers `NotFoundRow` (sans perle) et la perle disparaît d'un coup. |
| Appui long du mode courses : `DropdownMenu`, sans effet de mise à l'échelle | `ShoppingRows.RowMenu` | Rien ne bouge. L'ondulation (`ripple`) couvre toute la ligne, gouttière comprise : un voile passe sur le tronçon. |
| Écran Liste : ni glisser (corbeille), ni `animateItem` | `ListDetailScreen` | Le fil ne bouge pas aujourd'hui ; appui long corrigé par #112. Seule l'ondulation passe sur le tronçon. |
| Fonds | `AisleLine` et `ItemRowContent` : `.background(paper)` ou accent translucide (article ajouté) | Opaques par ligne. |

### 2.3 Pourquoi le fil « casse »

Le fil est dessiné **par morceaux, un par ligne**. Deux familles de mouvements en découlent :

1. **Horizontaux** (glisser, soulever, enfoncer) : la ligne bouge en bloc, son morceau avec elle. On les règle en
   séparant, dans la ligne, une **gouttière** fixe et un **couloir** mobile.
2. **Verticaux** (tri, insertion, retrait, hauteur qui change) : chaque ligne glisse pour son compte. Tant que le trait
   est fait de morceaux portés par les lignes, ces morceaux se croisent, se raccordent mal ou s'effacent en fondu. On
   ne les règle qu'en dessinant le trait **une seule fois**, hors des lignes, ou en renonçant au glissement.

## 3. Vocabulaire commun (iOS et Android, à reporter dans `SYNC.md`)

| Nom | Rôle |
| --- | --- |
| `ThreadTrack` | Le trait : une seule ligne verticale par liste, du premier au dernier marqueur, parcourue (accent) jusqu'à la perle suivante. |
| `ThreadGutter` | Colonne fixe de chaque ligne, à gauche : porte la perle ou le nœud. Jamais décalée, mise à l'échelle ni soulevée. |
| `RowLane` | Couloir mobile de la ligne : case, libellé, points de conduite, quantité, marque d'auteur. Seule partie qui glisse, s'enfonce ou se soulève. |
| `threadMarker` | Hauteur de la perle dans la ligne : centre de la case (article) ou du titre (rayon). |

## 4. Architectures possibles

### A. Gouttière fixe dans chaque ligne, tri sans glissement

**Principe.** Chaque ligne garde son morceau de fil, mais dans une `ThreadGutter` qui ne fait pas partie du couloir
mobile. Le glisser, l'enfoncement et le menu n'agissent que sur `RowLane`. Pour le tri, on supprime le glissement :
les lignes changent de place d'un coup (comme aujourd'hui en mouvement réduit) et seul le contenu des couloirs passe en
fondu enchaîné.

- **Perle et ancrage.** Inchangés en pratique : iOS garde l'ancre de la case (mieux : un guide d'alignement, voir B) ;
  Android garde le centre de ligne.
- **Glisser.** iOS : impossible avec `.swipeActions`, qui décale toute la cellule et dont le glisser complet recouvre
  la gouttière : il faut un glisser maison (voir B). Android : `SwipeToDismissBox` descend dans le couloir.
- **Tri.** Les lignes changent de place d'un coup (comme aujourd'hui en mouvement réduit) : le trait est identique
  avant et après, donc il ne « bouge » pas, mais perles et nœuds sautent de place. Le geste visuel « cet article a
  changé de place » disparaît (il reste l'étiquette « ↑ appris » et l'annonce VoiceOver / TalkBack).
- **Insertion, retrait.** Même règle : pas de fondu, la ligne apparaît ou disparaît d'un coup.
- **Coût.** Moyen, porté surtout par le glisser maison iOS. **Risque.** Faible ; perte du glissement du tri, qui
  avait été demandé (`motion.reorder`).

### B. Trait unique sous la liste, perles dans une gouttière fixe (recommandée)

**Principe.** Trois couches :

1. `ThreadTrack` : le trait est dessiné **une fois** par liste, derrière les lignes, à abscisse fixe. Il ne connaît
   que trois hauteurs : premier marqueur, perle suivante, dernier marqueur. Il va de la première à la dernière, en
   accent jusqu'à la perle suivante, puis à parcourir (plein, ou pointillé sur Android en apprentissage).
2. `ThreadGutter` : chaque ligne ne dessine plus que sa perle ou son nœud (fond papier opaque, qui masque le trait
   dessous). La gouttière ne glisse, ne s'enfonce et ne se soulève jamais.
3. `RowLane` : seul le couloir bouge (glisser, appui, menu, coche).

Les lignes deviennent transparentes dans la gouttière (le papier passe sous la liste) pour laisser voir le trait.

- **Perle et ancrage.**
  - iOS : `ThreadRow` devient `HStack(alignment: .threadMarker) { ThreadGutter; RowLane }`, avec un
    `VerticalAlignment` personnalisé que la case définit (`alignmentGuide(.threadMarker) { $0[VerticalAlignment.center] }`),
    et le titre pour un rayon. C'est une valeur de **mise en page** : `offset`, `scaleEffect` et l'aperçu soulevé
    (effets de rendu) ne la modifient pas, contrairement à l'ancre actuelle. Dynamic Type jusqu'à AX5, ligne
    « suivante » en `title3`, libellé replié (case alignée sur la première ligne) : la case décide, comme aujourd'hui.
    `anchorPreference` et le `GeometryReader` de `ThreadRow` disparaissent. Le guide ne traverse que des `HStack`,
    `padding` et `frame` (la case est sœur de `LeaderLineLayout`, pas dedans). Le marqueur de la gouttière est posé
    dans un cadre de **hauteur nulle** (`.frame(width: gutter, height: 0)`) qui déborde : sinon le nœud de rayon
    (28 pt, centré sur un titre à ~10 pt du bas de `AisleLine`) agrandirait la ligne, alors qu'il déborde sans effet
    aujourd'hui.
  - Android : la gouttière est une `Box` de la `Row` en `CenterVertically`, la case aussi : perle au centre, comme
    aujourd'hui. (Écart existant, inchangé : sur un libellé replié, iOS aligne la case sur la première ligne, Android
    la centre. À noter dans `SYNC.md`, hors périmètre.)
- **Positions du trait.** Seules les lignes première, suivante et dernière du fil publient la hauteur de leur
  marqueur, dans le repère de la liste :
  - iOS : `onGeometryChange(for: CGFloat.self)` sur la perle, repère nommé posé sur la `List`, vers un
    `@Observable ThreadTrackModel` lu par un `Canvas` en `.background` de la `List`.
  - Android : position de la gouttière (`onPlaced`, ou `onGloballyPositioned` / `onLayoutRectChanged` si `onPlaced`
    n'est pas rappelé quand seul l'élément parent est replacé : à trancher au lot 0) vers un `ThreadTrackState`, lu
    **dans la phase de dessin** d'un `drawBehind` posé sur la `LazyColumn` (une lecture en dessin n'invalide que le
    dessin). L'étirement de bord (Android 12+) déforme le dessin sans changer les positions : bouts légèrement décalés
    le temps de l'étirement, accepté.
  - Lignes hors écran : une `List` ou une `LazyColumn` ne les instancie pas, et une position gardée peut être périmée.
    On décide par les **indices** des lignes visibles (iOS : `onScrollVisibilityChange` ou `onAppear` /
    `onDisappear` ; Android : `layoutInfo.visibleItemsInfo`) : premier marqueur au-dessus de l'écran, le trait part du
    bord haut ; dernier au-dessous, il va jusqu'au bord bas ; perle suivante au-dessus, tout le visible est à
    parcourir ; au-dessous, tout est en accent.
  - Pointillés Android (ordre générique ou en apprentissage) : phase calée sur le premier marqueur, pour qu'ils
    défilent avec le ticket. Le motif ne repart plus à chaque ligne : les captures Roborazzi en pointillés sont à
    régénérer.
  - Écriture de droite à gauche : `Thread.kt` inverse déjà l'abscisse ; le `drawBehind` de la liste et le `Canvas`
    iOS le font aussi (gouttière à droite, glisser inversé).
  - Clés Android : les clés de la `LazyColumn` sont préfixées par section (`"nf-…"`, `"basket-…"`) pour qu'une ligne
    qui change de section sorte en fondu puis entre en fondu, au lieu de glisser hors du fil. Les perles pleines du
    panier Android (sans trait) ne comptent pas comme dernier marqueur ; iOS n'en a pas : écart à noter dans
    `SYNC.md`.
- **Glisser.**
  - iOS : glisser maison sur `RowLane` (§6.2). Le couloir est rogné au bord droit de la gouttière : en glissant vers
    la gauche, la case passe sous ce bord ; le bouton « Supprimer » ou « Pas trouvé » apparaît dans le couloir et, en
    glisser complet, ne remplit que le couloir.
  - Android : `SwipeToDismissBox` est placé **dans** le couloir (`Modifier.weight(1f).clipToBounds()`), la gouttière
    est sa voisine dans la `Row`. Les deux sens restent (droite : cocher, gauche : Pas trouvé).
- **Appui long, menu.** iOS : `.contextMenu` posé sur le couloir, avec `.contentShape(.contextMenuPreview, …)` :
  l'aperçu soulevé est le couloir seul. Le `Button` du mode courses prend un style à nous qui transmet `isPressed` à
  `ItemLine(pressed:)` (même enfoncement que l'écran Liste) au lieu d'atténuer tout le libellé. Android : l'ondulation
  est portée par le couloir ; la cible de toucher reste la ligne entière (≥ 48 dp).
- **Coche.** La case se remplit (`Motion.check`), la perle passe pleine sur place, la partie parcourue coule le long
  du trait jusqu'à la nouvelle perle suivante (hauteur animée avec `Motion.check`).
- **Tri, insertion, retrait.** Les couloirs et les gouttières glissent verticalement avec leur ligne (UIKit ou
  `animateItem`, inchangés) : perles et nœuds **glissent le long du trait**, à abscisse fixe. Le trait ne bouge pas ;
  ses bouts suivent le premier et le dernier marqueur, avec la même courbe (`Motion.reorder` /
  `TicketMotion.reorder`). En pratique le bout haut ne bouge presque jamais (le premier rang a la même place avant et
  après un tri) ; en mode courses les lignes partent surtout par le haut, donc le bout bas se raccourcit à chaque
  départ, en suivant la dernière perle qui remonte. Une perle qui entre ou sort apparaît ou s'efface en fondu **sur**
  le trait, qui reste plein dessous ; si c'est la dernière perle qui part, le trait ne se raccourcit **qu'après** son
  fondu, pour qu'elle ne flotte jamais hors du trait.
- **Défilement.** Le trait est vertical : il ne dépend du défilement que par ses bouts. Un retard de mesure peut
  produire un trait trop long (rattrapable : la première et la dernière ligne peignent du papier dans leur gouttière
  au-delà de leur marqueur) ou trop court (trou entre le bout et la perle, non rattrapable). C'est le point à mesurer
  au lot 0 sur iOS.
- **Coût.** Moyen : un composant de trait par plateforme, une gouttière, un couloir, le glisser maison iOS.
- **Risques.** Sur iOS, synchronisation des bouts et de la jonction avec les perles, pendant le tri et le lancer
  (`List` adossée à UIKit, §5) ; `contextMenu`, glisser maison et style de bouton réunis sur un couloir placé dans le
  label d'un `Button` ; geste retour du bord d'écran. Tous vérifiables par de petits prototypes avant
  l'implémentation (§7).

### C. Fil entier dessiné en une couche (perles comprises)

**Principe.** Un seul `Canvas` (iOS) ou `drawBehind` (Android) dessine trait, perles et nœuds à partir des positions
de **toutes** les lignes. Les lignes ne contiennent plus que leur couloir.

- **Perle et ancrage.** Chaque ligne publie la hauteur de sa case ; Dynamic Type et libellés repliés sont gérés par la
  mesure. Nœuds de rayon : l'icône est dessinée dans la couche (symbole résolu).
- **Tri.** Les perles doivent suivre les lignes **image par image**. Sur Android, `onPlaced` le permet (à une image
  près). Sur iOS, une `List` est animée par Core Animation : les mesures donnent la position **finale**, les perles
  quitteraient leur case pendant 0,4 s. Il faudrait remplacer `List` par `ScrollView` + `LazyVStack`, donc perdre
  `.swipeActions`, le `DisclosureGroup` du panier tel quel, les comportements natifs de liste et reprendre les audits.
- **Glisser, menu.** Comme B.
- **Coût.** Élevé (iOS surtout). **Risques.** Élevés : migration de la liste iOS, accessibilité des lignes à
  revalider, performances du redessin de toutes les perles à chaque image.

### Comparaison

| | A. Gouttière, tri sans glissement | **B. Trait unique + gouttière** | C. Tout en une couche |
| --- | --- | --- | --- |
| Glisser, menu, appui | Conforme | Conforme | Conforme |
| Tri, insertion, retrait | Conforme, mais plus de glissement | Conforme, perles glissent le long du trait | Conforme ; iOS sans `List` |
| Hauteur qui change (ligne suivante) | Saut | Trait continu | Trait continu |
| Ancrage de la perle | Inchangé | Guide d'alignement (iOS), centre (Android) | Mesure de chaque case |
| Accessibilité | Actions explicites | Actions explicites | Actions explicites + reprise des audits de liste iOS |
| Coût estimé | ~3 j | ~4,5 j (lot 0 compris) | ~7 j et plus |
| Risque | Faible | Moyen sur iOS, levé ou non par le lot 0 | Élevé |

## 5. Recommandation : B

B est la seule architecture qui respecte la règle **et** garde le tri animé du mode courses, sans quitter `List` sur
iOS. Elle découle directement du constat : les mouvements horizontaux se règlent par la séparation gouttière /
couloir, les mouvements verticaux par un trait qui n'appartient à aucune ligne. Les perles, elles, peuvent rester
dans les lignes : elles glissent verticalement avec leur article, toujours sur le trait, et elles sont synchronisées
avec leur case par construction (même cellule, même animation). C'est ce qui évite le coût de C.

A reste un bon repli si le lot 0 montre que les bouts du trait ne suivent pas le défilement iOS : on garderait la
gouttière et le glisser maison, en renonçant au glissement du tri.

Limite honnête de B sur iOS : seules les **perles** sont synchronisées par construction. Les bouts du trait et la
jonction accent / à parcourir sont dessinés hors de la `List`, d'après des positions mesurées ; rien ne garantit que
UIKit anime les cellules avec le même ressort que `Motion.reorder`, ni que la mesure suit un lancer rapide sans retard
(à 120 Hz, une image de retard peut dépasser le rayon de 14 pt d'un nœud). Le lot 0 tranche ce point avec un critère
chiffré (§7) ; Android n'est pas concerné, la mise en place précédant le dessin dans la même image.

## 6. Spécification du comportement (option B)

### 6.1 Par situation

| Situation | Couloir (`RowLane`) | Gouttière (`ThreadGutter`) | Trait (`ThreadTrack`) |
| --- | --- | --- | --- |
| Repos | — | — | Identique à aujourd'hui (captures actuelles inchangées), sauf les pointillés Android, dont le motif suit désormais tout le trait. |
| Glisser (en cours, ouvert, complet) | Glisse, rogné au bord de la gouttière ; action révélée dans le couloir | Immobile | Immobile |
| Toucher / appui long | S'enfonce (0,97, depuis le bord gauche) ; Android : ondulation dans le couloir | Immobile | Immobile |
| Menu contextuel iOS | Soulevé seul | Immobile, sous le voile du menu comme le reste de l'écran | Immobile, sous le voile |
| Coche | Case remplie, texte barré ; la ligne reste en place 600 ms | Perle pleine sur place | La partie parcourue coule jusqu'à la perle suivante |
| Ligne qui part (panier, introuvable) | Fondu (Android : clé préfixée par section) | Perle en fondu | Plein dessous ; bout bas raccourci avec la dernière perle, ou après le fondu si c'est elle qui part |
| Tri, rayon « ↑ appris » | Glisse verticalement | Glisse le long du trait | Immobile |
| Mouvement réduit | Pas de glissement (comme aujourd'hui) ; glisser du couloir sans rebond | Change de place d'un coup | Immobile ; la partie parcourue change sans couler |
| Contraste augmenté | — | — | Trait plus épais (`threadWidthIncreased` / `threadWidthHighContrast`), couleur à parcourir renforcée |

### 6.2 Glisser maison iOS (`RowLane`)

- Reconnaissance par `UIGestureRecognizerRepresentable` (iOS 18) : un `UIPanGestureRecognizer` qui ne démarre que si
  le geste est d'abord horizontal. Il ne gêne ni le défilement de la `List`, ni le toucher, ni l'appui long.
- Le couloir est décalé par `.offset(x:)` et rogné ; l'action est un vrai bouton, révélé derrière le contenu,
  nommé « Supprimer » (écran Liste, glisser partiel) ou « Pas trouvé » (mode courses, glisser complet permis).
- Ce bouton **n'existe que ligne ouverte**, et il est posé **hors** de l'élément d'accessibilité regroupé de la ligne
  (`.accessibilityElement(children: .combine)`) : sinon il y serait fusionné et `app.buttons["Supprimer"]` ne le
  trouverait plus, ou `.firstMatch` viserait une autre ligne. Il reste accessible, comme les boutons du glisser
  système, ce qui garde valables les tests `swipeLeft()` puis `buttons["Supprimer"]`
  (`ParcoursesUITests`, `LiveActivityUITests`). Aucun test ne glisse vers « Pas trouvé » (on y passe par le menu,
  `ItemEditUITests`) : en ajouter un.
- Seuil d'ouverture fonction de la distance **et de la vitesse** (`swipeLeft()` est un geste court et rapide), rebond
  élastique, retour haptique au seuil du glisser complet, une seule ligne ouverte à la fois, fermeture au défilement
  ou au toucher ailleurs. Le geste retour du bord d'écran (écran Liste) garde la priorité.
- `ListsView` (écran des listes, sans fil) garde `.swipeActions`.

### 6.3 Accessibilité

- Trait et gouttière restent décoratifs (`accessibilityHidden` / `clearAndSetSemantics`).
- Le glisser n'est jamais la seule voie : iOS ajoute l'action « Supprimer » à `ListDetailView` (aujourd'hui fournie
  d'office par `.swipeActions`, qui disparaît) ; « Pas trouvé » existe déjà en action. Android : actions TalkBack
  inchangées.
- Focus et annonces après tri (`ReorderAnnouncement`) inchangés.
- Écriture de droite à gauche : gouttière à droite, sens du glisser inversé, comme les composants système.

### 6.4 Tests

- **Gouttière invariante** (nouveau, les deux plateformes) : rendre une ligne au repos, puis couloir décalé, enfoncé
  et soulevé, et comparer les pixels de la gouttière et du trait : ils doivent être identiques. Android : Roborazzi ;
  iOS : `ImageRenderer` sur `ThreadRow` avec un décalage de couloir injecté.
- **Trait** : la fonction pure qui donne les tronçons à partir de (premier, suivante, dernier, hauteur visible) porte
  le même nom et les mêmes cas des deux côtés.
- Captures Roborazzi actuelles inchangées ; audits XCUITest (défaut, AX5, sombre, contraste augmenté) inchangés.

## 7. Découpage proposé

| Lot | Contenu | Estimation |
| --- | --- | --- |
| 0. Prototypes isolés, hors de l'app | **iOS** : dans une `List` de 30 lignes, mesurer l'écart entre les bouts du trait, la jonction accent / à parcourir et leurs perles, pendant un tri, un départ au panier et un lancer rapide (enregistrement d'écran image par image) ; `contextMenu`, pan horizontal et style de bouton réunis sur un couloir placé dans le label d'un `Button` ; pan contre le défilement et contre le geste retour ; sens en RTL. **Android** : `onPlaced` contre `onGloballyPositioned` / `onLayoutRectChanged` sous `animateItem` et au défilement ; lecture en dessin sur la `LazyColumn`. | ½ j |
| 1. Android | `ThreadTrack`, gouttière, couloir, `SwipeToDismissBox` dans le couloir, ondulation, clés par section, tests, captures en pointillés régénérées | ~1,5 j |
| 2. iOS | `ThreadTrack`, `.threadMarker`, gouttière, couloir, glisser maison, `contextMenu` et style de bouton, tests | ~2,5 j |

**Critère de repli vers A (iOS)** : si, au lot 0, un bout ou la jonction s'écarte de sa perle de plus de 7 pt (la
moitié du rayon d'une perle) sur une image, pendant un tri ou un lancer, ou laisse un trou entre le trait et une
perle, iOS passe en A (tri sans glissement) ; Android garde B. L'écart entre plateformes serait noté dans `SYNC.md`.

Chaque lot fait l'objet d'une PR séparée, avec captures avant / après et `SYNC.md` à jour.

## 8. Décisions (validées le 2026-11-17)

Option **B** retenue, avec la recommandation sur les six questions posées.

1. **D1, tri.** Pendant un tri, les perles et les nœuds **glissent le long du trait** avec leur ligne, à abscisse
   fixe.
2. **D2, glisser iOS.** Le couloir est **rogné** au bord droit de la gouttière : la case passe sous ce bord en
   glissant vers la gauche (pas de fondu).
3. **D3, surlignage.** L'article tout juste ajouté n'est surligné **que dans son couloir** ; la gouttière reste
   papier.
4. **D4, menu contextuel iOS.** On garde le menu contextuel d'Apple. Son voile couvre tout l'écran, fil compris ; le
   fil reste immobile sous le voile. Pas de menu maison.
5. **D5, glisser maison iOS.** Un glisser maison remplace `.swipeActions` sur l'écran Liste et le mode courses (§6.2),
   en **conservant les actions d'accessibilité** (« Supprimer », « Pas trouvé ») et les tests qui s'appuient sur le
   bouton révélé.
6. **D6, bouts du trait.** Le trait peut **s'allonger et se raccourcir par ses bouts** quand le premier ou le dernier
   marqueur change ; il ne se déplace jamais.

Suite : lot 0 (prototypes) sur la branche `proto/115-lot0`, avec le critère de repli du §7 (7 pt) pour iOS.
