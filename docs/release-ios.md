# Publier l'app iOS (#145)

L'app se publie par [fastlane](https://docs.fastlane.tools), depuis `ios/`, sans passer à la main par Xcode ni par
App Store Connect. Quatre lanes :

| Commande (depuis `ios/`) | Ce qu'elle fait | Contacte Apple |
| --- | --- | --- |
| `bundle exec fastlane check` | Vérifie la fiche : limites de longueur, noms de fichiers, marques, catégories, URL, classification par âge | Non |
| `bundle exec fastlane screenshots` | Produit les captures App Store sur le simulateur iPhone 6,9 pouces | Non |
| `bundle exec fastlane beta` | Build Release signé, envoyé sur TestFlight pour les testeurs internes | Oui |
| `bundle exec fastlane metadata` | Envoie la fiche App Store en français, sans la soumettre à la revue | Oui |

Fichiers : `ios/Gemfile` et `ios/Gemfile.lock` (version de fastlane figée), `ios/fastlane/Fastfile`, `Appfile`,
`Snapfile`, la fiche dans `ios/fastlane/metadata/`, la classification par âge dans `ios/fastlane/age_rating.json` et
les captures dans `ios/fastlane/screenshots/fr-FR/`.

La soumission à la revue App Store et la bêta externe (#12) ne sont pas couvertes : elles se feront après validation
de la fiche.

## Prérequis

- **L'app existe dans App Store Connect** (*Apps → Nouvelle app* : iOS, bundle ID `app.parcourses`, SKU libre), avec
  le **français comme langue principale**. C'est déjà fait (id 6836288730). Sans elle, `beta` échoue dès la lecture
  du dernier numéro de build. Avec une autre langue principale, `metadata` ajouterait le français, mais la fiche de
  la langue principale resterait vide.
- **Xcode** à jour, et **XcodeGen 2.46.0**, la version de la CI (voir `ios/README.md`). Les lanes régénèrent le projet
  avant chaque build.
- **Ruby 3.2 ou plus**, avec Bundler. Le Ruby de macOS est trop ancien : prendre celui de Homebrew (`brew install
  ruby`). Puis, une fois :

  ```sh
  cd ios
  bundle config set --local path ~/.cache/parcourses/bundle
  bundle install
  ```

  Les gems vont hors du dépôt : installées dans `ios/`, leurs fichiers Swift feraient échouer
  `xcrun swift-format lint -r .`, qui ne sait pas exclure un dossier.

- **Compte de l'équipe `QMJKZ67Z3H` connecté dans Xcode** (*Réglages → Comptes*), avec le rôle Admin ou Titulaire du
  compte. La signature est automatique : au premier build, Xcode crée le certificat de distribution et les profils de
  l'app (`app.parcourses`) et de son extension (`app.parcourses.widgets`).
- **`ios/Config/Cloud.xcconfig`** renseigné (copie de `Cloud.xcconfig.example`) : URL et clé publiable du projet
  Supabase hébergé. Sans lui, un build Release n'aurait pas de serveur. `beta` refuse de partir s'il manque ou s'il
  contient encore les valeurs d'exemple.
- **Distribution automatique** activée sur le groupe de testeurs internes (*TestFlight → Testeurs internes →
  le groupe → Distribution automatique*). Un build est alors proposé aux testeurs dès qu'Apple a fini de le traiter :
  `beta` n'attend pas ce traitement.

## Créer la clé d'API App Store Connect (une fois)

`beta` et `metadata` s'authentifient par une clé d'API, jamais par un identifiant Apple ni un code à deux facteurs.

1. Dans [App Store Connect](https://appstoreconnect.apple.com) : *Utilisateurs et accès → Intégrations → App Store
   Connect API → Clés d'équipe*. La première fois, il faut demander l'accès à l'API (Titulaire du compte).
2. *Générer une clé d'API* : nom « fastlane Parcourses », accès **App Manager**. Ce rôle suffit pour TestFlight et
   la fiche ; il ne permet pas de gérer les utilisateurs ni les contrats.
3. Noter l'**ID de la clé** (10 caractères, colonne « ID de la clé ») et l'**ID de l'émetteur** (UUID, en haut de la
   page).
4. Télécharger la clé `AuthKey_<ID de la clé>.p8`. **Apple ne la propose qu'une fois** : la ranger aussitôt.

   ```sh
   mkdir -p ~/.config/parcourses
   mv ~/Downloads/AuthKey_ABC123DEFG.p8 ~/.config/parcourses/
   chmod 600 ~/.config/parcourses/AuthKey_ABC123DEFG.p8
   ```

5. Créer `~/.config/parcourses/app-store-connect.env` :

   ```sh
   APP_STORE_CONNECT_API_KEY_KEY_ID=ABC123DEFG
   APP_STORE_CONNECT_API_KEY_ISSUER_ID=00000000-0000-0000-0000-000000000000
   # Facultatif : chemin de la clé, par défaut ~/.config/parcourses/AuthKey_<ID de la clé>.p8
   # APP_STORE_CONNECT_API_KEY_KEY_FILEPATH=~/.config/parcourses/AuthKey_ABC123DEFG.p8
   ```

   Ces variables peuvent aussi venir de l'environnement, qui l'emporte sur le fichier. Le Fastfile refuse une clé
   lisible par d'autres comptes que le vôtre (`chmod 600`).

Rien de tout cela ne va dans le dépôt : `*.p8` et `*.env` sont ignorés par git. En cas de fuite, révoquer la clé sur
la même page d'App Store Connect et en générer une autre.

## Envoyer un build sur TestFlight

```sh
cd ios
bundle exec fastlane beta
```

1. Vérifie qu'aucun fichier suivi n'est modifié : le build envoyé doit correspondre à un commit.
2. Vérifie `Config/Cloud.xcconfig`, régénère le projet (XcodeGen).
3. Lit le dernier numéro de build sur TestFlight et prend le suivant (`latest_testflight_build_number + 1`). Le
   numéro s'applique à l'app et à l'extension par `CURRENT_PROJECT_VERSION`, sans modifier de fichier.
4. Archive en Release, signé automatiquement pour l'équipe `QMJKZ67Z3H`, et exporte l'IPA dans `ios/build/`.
5. Envoie l'IPA et ses symboles sur TestFlight, sans attendre le traitement d'Apple, puis supprime `ios/build/`.

La version affichée vient de `MARKETING_VERSION` dans `ios/Config/Base.xcconfig` (`0.1.0` au départ). Pour une
nouvelle version, la changer dans une PR. La question du chiffrement n'est pas posée à chaque build :
`ITSAppUsesNonExemptEncryption = NO` est dans l'Info.plist, et un test le vérifie (l'app n'utilise que le HTTPS
standard, exempté).

**Vérifier ensuite** : un e-mail d'Apple annonce la fin du traitement (5 à 30 min). Le build apparaît dans
*TestFlight → iOS*, puis chez les testeurs internes, dans l'app TestFlight.

## Produire les captures

```sh
cd ios
bundle exec fastlane screenshots
```

`snapshot` joue les tests UI du scheme `ParcoursesScreenshots` sur un « iPhone 17 Pro Max » (6,9 pouces,
1320 × 2868), en français, barre d'état propre (9:41), avec des données de démonstration. Les PNG arrivent dans
`ios/fastlane/screenshots/fr-FR/` et sont commités avec la fiche. Il faut un simulateur « iPhone 17 Pro Max » (Xcode
le fournit) et environ 4 Gio libres pendant le build. Le dossier de build temporaire est supprimé à la fin.

**Attention : ce simulateur est effacé** avant les captures (`erase_simulator`), données et réglages compris, pour
partir d'un état neutre. N'utilisez pas le même « iPhone 17 Pro Max » pour vos essais, ou acceptez d'y perdre ce
qu'il contient.

Seule la taille 6,9 pouces est exigée pour l'iPhone : App Store Connect la réduit pour les autres tailles. L'app ne
cible pas l'iPad (`TARGETED_DEVICE_FAMILY = 1`).

## Envoyer la fiche App Store

```sh
cd ios
bundle exec fastlane check      # sans contacter Apple, à faire d'abord
bundle exec fastlane metadata
```

`metadata` relance `check`, puis envoie avec `deliver`, pour la langue `fr-FR` et la version `MARKETING_VERSION` :

- nom, sous-titre, description, mots-clés, texte promotionnel (`metadata/fr-FR/*.txt`) ;
- URL de support, URL marketing et URL de la politique de confidentialité ;
- catégories (`metadata/primary_category.txt`, `secondary_category.txt`) et copyright (`metadata/copyright.txt`) ;
- classification par âge (`age_rating.json`) ;
- captures de `screenshots/fr-FR/`, qui remplacent celles en ligne (si le dossier est vide, les captures en ligne ne
  bougent pas).

Rien n'est soumis à la revue (`submit_for_review: false`), et aucun binaire n'est envoyé.

**Vérifier ensuite**, dans App Store Connect, sur la version en préparation : textes et captures, catégories, âge
« 4+ » dans *Informations sur l'app*.

### Choix faits pour la fiche

- **Catégorie principale : Achats** (`SHOPPING`), **secondaire : Productivité** (`PRODUCTIVITY`). L'app sert pendant
  les courses, au magasin, et c'est sous « Achats » que l'on cherche une liste de courses. « Productivité » couvre
  l'organisation de la liste et son partage. Apple demande la catégorie qui décrit la fonction principale : une liste
  rangée pour faire ses courses relève plus des achats que de l'organisation en général.
- **Âge : 4+.** Pas de publicité, pas de navigateur web, pas de réseau social ni de messagerie, aucun thème sensible :
  ces réponses sont « Aucun » ou « Non ». Une seule réponse est « Oui » : **contenu généré par les utilisateurs**. Les
  libellés que chacun tape alimentent le catalogue commun, qui les propose ensuite à tous en autocomplétion (après
  plusieurs revendications et le filtre des termes refusés, #47 et #138). C'est du contenu d'utilisateur diffusé
  largement, au sens d'Apple. Cette réponse ne relève pas la classe d'âge, mais l'App Review peut alors vérifier la
  règle 1.2 : filtrer le contenu (fait), pouvoir le retirer (`unpublish_product`, côté serveur) et le signaler. Les
  listes partagées, elles, ne sont visibles que des personnes invitées par e-mail.
- **Pas de marque** dans les textes (vérifié par `check`, « caddie » compris) ni dans les captures : les magasins de démonstration ont des noms génériques
  (« Supermarché des Halles »), et les exemples de fautes de frappe sont des produits (« yahourt »).
- **URL de support** : la page d'accueil du site, dont le pied de page donne l'adresse de contact.

## Ce qui reste à faire dans App Store Connect

Ces réglages ne passent pas par fastlane, ou pas encore :

- *Prix et disponibilité* : gratuit, pays de diffusion.
- *Informations pour la revue* (contact, notes pour le relecteur), au moment de la soumission. Le relecteur se connecte
  avec le compte de revue (#149) : adresse et code fixes, réglés comme le décrit `docs/hosted-supabase.md`, section
  « Compte de revue des stores (#149) ». Les mêmes identifiants vont dans les informations de test de TestFlight.
- *Confidentialité de l'app* : déjà remplie (voir `docs/app-store-privacy.md`).

## Mettre fastlane à jour

```sh
cd ios
bundle update fastlane
bundle exec fastlane check
```

Commiter `Gemfile` et `Gemfile.lock` dans une PR. Si une nouvelle version de fastlane change le questionnaire d'âge,
`check` le signale (réponse manquante ou clé inconnue dans `age_rating.json`). `SnapshotHelper.swift`, copié dans les
tests UI, doit suivre la version de fastlane : `snapshot` prévient s'il est périmé.
