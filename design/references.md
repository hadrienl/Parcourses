# Parcourses : références design 2025-2026

> Veille du 31 octobre 2026 pour le designer produit. Toutes les pages citées ont été ouvertes.
> **Limites d'accès** :
> - **Dribbble** n'était pas lisible lors de la première passe. Il a été parcouru ensuite dans un navigateur : voir la section 4 bis.
> - **Behance** et **Mobbin** ont renvoyé une erreur 403.
> - **Page Flows** est partiellement lisible, avec un lien Login et un essai payant.
> - **Tide Guide** a renvoyé une erreur TLS.
> - Les pages **HIG** (Materials, Live Activities) et **m3.material.io** (motion, shape) se sont ouvertes, mais elles sont rendues en JavaScript : seuls le titre ou le résumé sont lisibles.
>
> Les règles « officielles » ci-dessous viennent donc surtout des pages Apple Newsroom et developer.apple.com (Adopting Liquid Glass), de developer.android.com, de design.google et de blog.google.
> **À revérifier dans un navigateur** : le contenu détaillé de la HIG et de m3.material.io.

---

## 1. Tendances visuelles 2025-2026

### Matériaux : du verre réservé aux contrôles
- Le verre réfracte, reflète et réagit au mouvement. Les contrôles forment une **couche fonctionnelle distincte au-dessus du contenu**, et la tab bar se rétracte pendant le défilement. Source : [Apple Newsroom, nouveau design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/).
- Sous Android 16, un léger flou derrière le volet de notifications apporte de la profondeur, sans verre généralisé. Source : [blog.google, M3 Expressive](https://blog.google/products/android/material-3-expressive-android-wearos-launch/).
- **Pour Parcourses** : la liste est le contenu et ne reçoit jamais d'effet verre. Le verre va à la barre de saisie, au bouton « Terminer » et à l'indicateur de magasin, qui flottent en bas.

### Formes : expressives et porteuses de sens
- M3 Expressive propose une bibliothèque de **35 formes**, le **morphing** entre formes et une échelle de coins qui fonctionne « comme l'échelle typographique ». Sources : [m3 Shape](https://m3.material.io/styles/shape/overview-principles) (résumé seul) et [Compose Material 3](https://developer.android.com/develop/ui/compose/designsystems/material3).
- **Pour Parcourses** : une coche qui passe d'un cercle à une forme « cookie » ou « fleur » à la validation, sous Android. Sous iOS, une animation SF Symbol suffit.

### Couleur : audacieuse mais hiérarchisante
- La recherche Google mesure qu'on repère les éléments clés jusqu'à **4 fois plus vite** dans un design expressif. Exemple : un bouton « Envoyer » plus grand, dans une couleur secondaire, près du clavier. Source : [design.google, recherche Expressive](https://design.google/library/expressive-material-design-google-research).
- Sous iOS, la teinte du verre reste rare et va à l'action principale. Source : [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).
- **Pour Parcourses** : une seule couleur de marque forte, portée par l'action principale (ajouter, terminer) et par le « fil » du trajet. Tout le reste est neutre.

### Typographie : affirmée, chiffres expressifs
- M3 Expressive met en avant une « emphasized typography ». Source : [blog.google](https://blog.google/products/android/material-3-expressive-android-wearos-launch/).
- Tide Guide, Apple Design Award 2026 dans la catégorie Visuals and Graphics, montre des données au rendu graphique soigné. Source : [ADA](https://developer.apple.com/design/awards/).
- **Pour Parcourses** : un gros chiffre « 7 restants » ou « 70 % cartographié » en graisse forte. Les noms d'articles restent dans une graisse régulière, très lisible.

### Mouvement : ressorts physiques et sens
- Le système de mouvement physique de M3 distingue les **ressorts spatiaux** (position, taille) des **ressorts d'effets** (couleur, opacité), avec un schéma expressif et un schéma standard. Source : [m3 Motion](https://m3.material.io/styles/motion/overview/how-it-works) (résumé seul).
- Things : « *Lovely, unfolding animations keep your place* » (WIRED), et chaque animation a une raison d'être. Source : [Things](https://culturedcode.com/things/).
- **Pour Parcourses** : le réordonnancement utilise des ressorts spatiaux. Le schéma standard sert au mode courses, le schéma expressif aux écrans calmes.

---

## 2. Patterns d'interaction

### 2.1 Coche
- **Ce qui marche** : un geste large et tolérant, un retour immédiat (haptique, forme et barré), une annulation sans confirmation. NN/g rappelle que les touches accidentelles sont fréquentes sur mobile et que l'annulation est essentielle. Source : [NN/g Mobile UX](https://www.nngroup.com/articles/mobile-ux/).
- **Exemple** : Bring! notifie les membres d'une liste partagée quand un article est acheté. La coche est donc un signal social. Source : [Bring!](https://www.getbring.com/en/home).
- **iOS** :
  - Appui sur toute la ligne, symbole animé et haptique `.success`.
  - Glisser vers la droite = cocher, menu contextuel au toucher prolongé.
  - Une bannière « Annuler » flottante en verre pendant 4 s.
- **Android** :
  - Toute la ligne est cliquable, avec un morphing de forme.
  - Un retour haptique de confirmation.
  - Une Snackbar « Annuler » au-dessus de la toolbar flottante.

### 2.2 Réordonnancement animé
- **Ce qui marche** : garder le contexte. Things « garde votre place ». La ligne touchée ne bouge pas : ce sont les autres qui glissent, avec un ressort court et sans dépassement.
- **Exemple** : [Things](https://culturedcode.com/things/), dont la réorganisation est décrite comme agréable et tactile.
- **iOS** : transition de liste SwiftUI à ressort, annonce VoiceOver « Liste réordonnée, prochain : lait ».
- **Android** : `animateItem()` dans la LazyColumn, ressort spatial du schéma standard, annonce TalkBack équivalente.
- **Mouvement réduit** : un fondu croisé.

### 2.3 Saisie rapide
- **Ce qui marche** : saisir au rythme de la pensée, en langage naturel. Todoist : « *Capture tasks at the speed of thought* ». Source : [Todoist](https://www.todoist.com/).
- La recherche Google montre qu'on repère plus vite un bouton d'envoi grand et proche du clavier. Source : [design.google](https://design.google/library/expressive-material-design-google-research).
- **À viser pour Parcourses** :
  - « 2 laits demi-écrémé » donne la quantité et l'article.
  - La catégorie est déduite.
  - Les recettes s'ajoutent en un clic, comme dans Bring!.
- **iOS** : un champ en verre ancré en bas, au-dessus du clavier, avec des suggestions en pastilles.
- **Android** : un champ dans la toolbar flottante en bas ; le bouton d'ajout est grand, de forme expressive, dans la couleur secondaire.

### 2.4 Choix du lieu
- **Ce qui marche** : utiliser le GPS plutôt que de demander une saisie. NN/g : exploiter les capacités du téléphone plutôt que demander un code postal. Source : [NN/g Mobile UX](https://www.nngroup.com/articles/mobile-ux/).
- **Exemple** : ce même principe NN/g. Il faut toujours prévoir le repli manuel (refus de localisation, position approximative).
- **iOS** : une sheet à détentes qui propose le magasin le plus probable en tête, et la liste proche en détente moyenne.
- **Android** : une bottom sheet ; predictive back ramène à la liste.

### 2.5 Progression des courses
- **Ce qui marche** : une information lisible d'un coup d'œil, hors de l'app.
- Android 16 : les **notifications de progression** (`ProgressStyle`) pour un parcours initié par l'utilisateur, avec un début et une fin. Elles comportent des **segments** (portions du parcours), des **points** (jalons), une icône de suivi personnalisable et des actions utiles. Source : [Android, notifications progress-centric](https://developer.android.com/develop/ui/views/notifications/progress-centric).
- Flighty promet les infos essentielles « *all at a glance* ». Source : [Flighty](https://flighty.com/).
- **iOS** : une Live Activity.
  - Vue compacte : « 7 restants ».
  - Vue minimale : un anneau de progression.
  - Vue étendue : prochain rayon et prochain article.
  - Elle se termine à la fin des courses.
- **Android** : une Live Update dont chaque segment est un rayon et chaque point un article. L'icône de suivi est un caddie, et l'action est « Cocher le suivant ».

### 2.6 États vides
- **Ce qui marche** : montrer l'essentiel d'abord et donner l'action suivante. NN/g recommande de concevoir pour les interruptions, en sauvegardant l'état pour reprendre où on en était. Source : [NN/g Mobile UX](https://www.nngroup.com/articles/mobile-ux/).
- **Exemple** : non sourcé directement, car Mobbin a renvoyé une 403.
- **Pour Parcourses** : une liste vide = une illustration du « fil » enroulé + le champ de saisie déjà actif.
- **Hors ligne** : la liste reste utilisable, sans écran d'erreur bloquant.
- **iOS et Android** : même illustration et même texte, chacun avec ses contrôles natifs.

### 2.7 Onboarding
- **Ce qui marche** : une à deux étapes et aucun compte. Page Flows montre des onboardings iOS réels (Clay, Nike Run Club, Life360…). Source : [Page Flows, onboarding](https://pageflows.com/ios/flows/onboarding/) (accès partiel).
- **Pour Parcourses** : écran 1, la promesse animée (la liste qui se trie). Écran 2, la demande de localisation, au moment où elle sert.
- **iOS** : une sheet plein écran avec un bouton en verre à teinte de marque.
- **Android** : edge-to-edge, avec un indicateur de chargement expressif pendant la détection du magasin.

---

## 3. Spécificités Liquid Glass et M3 Expressive

### Liquid Glass (iOS 26+)
Sources : [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [Apple Newsroom](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/), [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) (non lisible hors navigateur).
1. Le verre est une **couche de contrôle et de navigation**, jamais du contenu.
2. Les **composants système** (NavigationStack, TabView, toolbars, sheets) adoptent Liquid Glass automatiquement. Il faut les préférer aux composants custom.
3. La **teinte** reste parcimonieuse et réservée à l'action principale.
4. On n'empile pas les couches de verre. Les éléments voisins se regroupent (`GlassEffectContainer`).
5. Les variantes :
   - `regular` : la variante par défaut, adaptative ;
   - `clear` : pour les fonds riches en médias, avec un voile d'assombrissement.
6. Il faut respecter Réduire la transparence, Augmenter le contraste et Réduire les animations, et maquetter le rendu opaque.
7. Les barres se rétractent au défilement. Le mode courses doit garder l'action principale accessible quand même.
8. Le **repli iOS 18** utilise les matériaux classiques (`.regularMaterial`).

### Live Activities
Source : [HIG Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities) (non lisible hors navigateur, à relire).
- Quatre présentations : écran verrouillé, Dynamic Island compacte, minimale et étendue.
- Le contenu reste court et se lit d'un coup d'œil.
- Les mises à jour restent sobres, et l'activité se termine explicitement à la fin des courses.

### Material 3 Expressive (Android 16)
Sources : [design.google](https://design.google/library/expressive-material-design-google-research), [blog.google](https://blog.google/products/android/material-3-expressive-android-wearos-launch/), [Compose M3](https://developer.android.com/develop/ui/compose/designsystems/material3), [m3 Motion](https://m3.material.io/styles/motion/overview/how-it-works) et [m3 Shape](https://m3.material.io/styles/shape/overview-principles) (résumés seuls).
1. **Leviers expressifs** : la couleur, la forme, la taille, le mouvement et la contenance (containment). Ils servent d'abord à **hiérarchiser** et à **grouper**.
2. **Formes** : une bibliothèque de 35 formes, le morphing, et une échelle de coins de extraSmall à extraLarge.
3. **Mouvement** : des ressorts spatiaux et des ressorts d'effets, avec un schéma expressif ou standard.
4. **Composants à étudier** :
   - la toolbar flottante, le FAB menu et les groupes de boutons ;
   - l'indicateur de chargement expressif ;
   - les Live Updates.
   Les noms des API Compose sont à vérifier dans la référence.
5. **Couleur dynamique** et typographie accentuée.
6. **Limites citées par Google** :
   - Ne pas casser les conventions.
   - Ne pas retirer les libellés : sur les actions d'e-mail, cela a nui à l'utilisabilité.
   - Une minorité préfère le calme.
   - Tester en continu.

---

## 4. Références coup de cœur

1. **[Things](https://culturedcode.com/things/)**
   - *Retenir* : des animations qui gardent la place de l'utilisateur, une réorganisation tactile.
   - *Ne pas copier* : son minimalisme blanc et gris, à l'opposé de l'ambition « fil d'Ariane ».
2. **[Todoist](https://www.todoist.com/)**
   - *Retenir* : la saisie en langage naturel.
   - *Ne pas copier* : la densité de fonctions (priorités, étiquettes, équipes).
3. **[Bring!](https://www.getbring.com/en/home)**
   - *Retenir* : le partage en temps réel et la notification « article acheté », les recettes en un clic, l'accès vocal.
   - *Ne pas copier* : les offres promotionnelles mêlées à la liste.
4. **[AnyList](https://www.anylist.com/)**
   - *Retenir* : le regroupement automatique par catégorie, un repli honnête quand le magasin est inconnu.
   - *Ne pas copier* : son esthétique utilitaire datée.
5. **[Flighty](https://flighty.com/)**
   - *Retenir* : des données « pilot-grade » rendues compréhensibles, un statut d'un coup d'œil (« Gate changed »), le modèle des Live Activities.
   - *Ne pas copier* : la densité de données. Parcourses n'affiche qu'un « prochain ».
6. **[Tide Guide](https://developer.apple.com/design/awards/)** (ADA 2026, Visuals and Graphics, finaliste Interaction ; site non accessible)
   - *Retenir* : des données naturelles transformées en graphisme beau.
   - *Ne pas copier* : les courbes détaillées.
7. **[Moonlitt](https://developer.apple.com/design/awards/)** (ADA 2026, Interaction)
   - *Retenir* : un seul geste riche pour explorer une donnée.
   - *Ne pas copier* : des gestes non standard en mode courses.
8. **[Structured](https://developer.apple.com/design/awards/)** (finaliste ADA 2026, Inclusivity)
   - *Retenir* : un planning visuel en fil chronologique, proche de la métaphore du trajet.
   - *Ne pas copier* : la timeline verticale telle quelle.
9. **[Watch Duty](https://www.apple.com/newsroom/2025/06/apple-unveils-winners-and-finalists-of-the-2025-apple-design-awards/)** (ADA 2025, Social Impact)
   - *Retenir* : une information collective, présentée de façon claire et fiable, qui construit la confiance (comparable au crowdsourcing de Parcourses).
   - *Ne pas copier* : l'urgence visuelle.
10. **[CapWords](https://www.apple.com/newsroom/2025/06/apple-unveils-winners-and-finalists-of-the-2025-apple-design-awards/)** (ADA 2025, Delight and Fun)
    - *Retenir* : des objets du quotidien transformés en autocollants, une piste pour l'illustration des articles.
    - *Ne pas copier* : l'aspect ludique dans le mode courses.
11. **[Android, Live Updates](https://developer.android.com/develop/ui/views/notifications/progress-centric)**
    - *Retenir* : des segments et des points, qui correspondent aux rayons et aux articles.
    - *Ne pas copier* : les couleurs de véhicule. Il faut adapter la métaphore.
12. **[Recherche M3 Expressive](https://design.google/library/expressive-material-design-google-research)**
    - *Retenir* : la taille et la couleur au service du repérage, y compris chez les plus de 45 ans.
    - *Ne pas copier* : l'expressivité partout.
13. **[Apple Newsroom, Liquid Glass](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)**
    - *Retenir* : des contrôles qui s'effacent devant le contenu et se transforment au besoin.
    - *Ne pas copier* : des contrôles qui disparaissent en mode courses (voir NN/g).

---

## 4 bis. Dribbble (parcouru le 31/10/2026)

Recherches : `grocery list`, `shopping list app`, `liquid glass app`, `material 3 expressive`, `checklist animation`, `indoor navigation app`, sur l'année écoulée.

**Constat général** : la grande majorité des shots « grocery » sont des apps de **livraison** ou de **nutrition et IA** (cartes produits, macros, chatbots). Presque aucun ne traite la **liste en magasin**, et aucun l'apprentissage du trajet. C'est un espace visuel libre pour Parcourses.

| Shot | Ce qu'on en retient | À ne pas copier |
| --- | --- | --- |
| [Automated In-Store Grocery List Map](https://dribbble.com/shots/4767092-The-Daily-Hack-7-Automated-In-Store-Grocery-List-Map) (Andrea Eppy, 2018) | Le concept le plus proche de Parcourses : un tracé en pointillés numéroté sur un plan de rayons, un bandeau « prochain article, allée 6 » façon GPS, et la liste en sheet avec l'allée sous chaque article. | Il suppose un plan de magasin connu, alors que nous ne l'avons pas. Notre « carte » doit être abstraite : un fil, une séquence, pas un plan d'allées. |
| [grocery list preview / interaction](https://dribbble.com/shots/25577935-grocery-list-preview-interaction) (proskü.a) | Des listes en cartes avec des **produits en vignettes détourées** façon stickers, une note manuscrite épinglée, une grande typographie noire et des filtres en pastilles (Épinglées, Récentes, Partagées). Une liste chaleureuse et tangible. | Une composition décorative illisible en mode courses. À réserver à l'écran des listes, à la maison. |
| [MeterStats 2 – Liquid Glass App UI](https://dribbble.com/shots/27463566-MeterStats-2-Liquid-Glass-App-UI) (Alexander Käßner) | Des cartes opaques **sous** une couche de verre limitée aux contrôles (bouton flottant, sélecteur de lieu en menu glass, navigation). Couleur d'accent franche (orange et violet) et chiffres très expressifs. L'auteur précise que les cartes sont « réglées pour fonctionner avec la couche de verre d'iOS 26 ». | — Bon exemple de la règle « verre sur les contrôles, contenu opaque ». |
| [Reservations, Material 3 Expressive](https://dribbble.com/shots/25913303-Mobile-App-Concept-Reservations-Material-3-Expressive) (Dan) | Carte de lieu en surface tonale sur une carte géographique, créneaux en pastilles arrondies, couleur tonale douce (vert sauge et jaune). Une bonne base pour l'écran **choix du magasin** sur Android. | Le rendu reste sage pour de l'« expressive ». Pousser davantage les formes et la typographie. |
| [Continente : liste et localisateur de magasins](https://dribbble.com/shots/3885899-Interface-Continente-s-grocery-list-and-store-locator) | Une enseigne qui associe la liste et le choix du magasin : le précédent le plus direct pour notre flux. | Non ouvert en détail, à regarder. |

**Pistes pour Parcourses tirées de ces shots :**

- **Le « fil » comme signature visuelle** : un trait continu qui relie les articles dans l'ordre du trajet et se « tend » à chaque coche. C'est l'équivalent abstrait du tracé de la Daily Hack 7, sans plan.
- **Un bandeau « prochain article »** en haut ou dans la Live Activity, façon guidage GPS.
- **Des vignettes produits en stickers** à la maison, et des **lignes textuelles sobres** en magasin : deux densités pour deux moments.

**Non couverts** : Mobbin et Behance (connexion requise ou 403), Material Design Awards.

---

## 5. Pièges à éviter

- **Illisibilité du verre** : selon NN/g, du texte posé sur un fond chargé devient illisible. Ne jamais poser de verre clair sur la liste. Source : [NN/g, Liquid Glass](https://www.nngroup.com/articles/liquid-glass/).
- **Animations décoratives** : les boutons qui pulsent ou les onglets qui oscillent distraient (NN/g). En magasin, toute animation doit expliquer quelque chose.
- **Contrôles imprévisibles** : NN/g critique les éléments qui apparaissent ou disparaissent selon le contexte. Le bouton « Terminer » et la saisie doivent rester stables.
- **Cibles serrées** : la barre d'onglets Liquid Glass paraît encombrée. Garder 44 pt et 48 dp au minimum, davantage pour la coche.
- **Sur-expressivité** : Google observe une baisse d'utilisabilité quand on retire les libellés ou qu'on désorganise la mise en page. Garder les libellés.
- **Gamification** : pas de badges, de séries ni de classements. La contribution s'exprime en une phrase sincère (« ce magasin est cartographié à 70 % grâce à vous ») dans un écran calme.
- **Transposer entre plateformes** : pas de verre sous Android, pas de FAB sous iOS (fiche du designer).
- **Oublier les interruptions et le réseau** : sauvegarder l'état et rester utilisable hors ligne (NN/g Mobile UX).
- **Confirmations bloquantes** : préférer l'annulation.
- **Jargon de l'apprentissage** : dire « en apprentissage », pas « confiance du modèle 0,62 ».

---

## Résumé en 10 lignes

1. Le verre (iOS) et l'expressivité (Android) se jouent sur les **contrôles**, pas sur le contenu de la liste.
2. Les composants système d'iOS 26 donnent Liquid Glass gratuitement : peu de custom, une teinte rare.
3. M3 Expressive mesure un repérage jusqu'à 4 fois plus rapide grâce à la taille, la couleur et la forme, mais retirer les libellés nuit.
4. Le mouvement est physique : ressorts spatiaux et ressorts d'effets, schémas standard et expressif.
5. Le réordonnancement doit « garder la place » de l'utilisateur, à la manière de Things.
6. Une saisie en langage naturel en bas de l'écran, avec un gros bouton d'envoi près du clavier.
7. Les Live Activities et les Live Updates (segments = rayons, points = articles) sont une vitrine idéale pour Parcourses.
8. NN/g met en garde contre la lisibilité du glass, les animations gratuites et les contrôles qui disparaissent.
9. Le mobile est interrompu et mal connecté : annulation plutôt que confirmation, état persistant, mode hors ligne.
10. Les sources de shots (Dribbble, Behance, Mobbin) sont restées inaccessibles et la HIG et M3 n'ont été lus que partiellement : à compléter dans un navigateur.
