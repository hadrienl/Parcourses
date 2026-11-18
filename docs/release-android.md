# Publier l'app Android sur Google Play

Ce document couvre la clé d'envoi, la construction de l'AAB signé, l'empreinte à déclarer pour les App Links et
l'envoi par fastlane. La bêta elle-même (testeurs, pistes, calendrier) est décrite dans l'issue #12.

## Deux clés : la clé d'envoi et la clé de signature de l'app

L'app utilise la **signature d'application Play** (*Play App Signing*) :

| Clé | Qui la détient | À quoi elle sert |
| --- | --- | --- |
| **Clé d'envoi** (*upload key*, « clé d'importation » dans la Play Console) | Nous, dans `~/.config/parcourses/upload.jks` | Signer l'AAB qu'on envoie à la Play Console. Google vérifie cette signature à l'envoi, puis la retire. |
| **Clé de signature de l'app** (*app signing key*) | Google | Signer les APK que Play installe sur les téléphones. C'est elle que voient Android et les App Links. |

Si la clé d'envoi est perdue ou compromise, on en demande une nouvelle à Google (*Play Console → Intégrité de l'app →
Signature de l'app → Demander la réinitialisation de la clé d'importation*). L'app installée n'en souffre pas, puisque
sa signature vient de la clé de Google. La réinitialisation prend toutefois quelques jours, sans aucun envoi possible
pendant ce temps.

### La clé d'envoi et sa sauvegarde

La clé d'envoi est un magasin PKCS12, avec l'alias `upload`. Elle n'entre jamais dans le dépôt : le `.gitignore`
refuse `*.jks`, `*.keystore`, `*.p12` et `*signing*.properties`.

| Fichier | Contenu | Droits |
| --- | --- | --- |
| `~/.config/parcourses/upload.jks` | La clé et son certificat | `600` |
| `~/.config/parcourses/android-signing.properties` | `storeFile`, `storePassword`, `keyAlias`, `keyPassword` (et `storeType` en option) | `600` |

Empreinte SHA-256 du certificat de la clé d'envoi :

```
63:3D:2C:38:C4:5A:2D:5F:2B:93:EC:B9:2C:CF:51:F2:A3:30:72:6D:DF:24:C7:E2:19:C3:F4:4D:60:3B:9F:91
```

**Sauvegarde.** Conserver `upload.jks` et ses mots de passe dans un gestionnaire de mots de passe (pièce jointe et
note sécurisée), et une seconde copie hors de la machine, par exemple sur une clé USB chiffrée. Les mots de passe ne
s'écrivent jamais dans un ticket, un commit, un log ou un message. Pour vérifier une sauvegarde sans afficher de
secret, le mot de passe est demandé de façon interactive :

```sh
keytool -list -v -keystore upload.jks -alias upload | grep SHA256
```

## Construire l'AAB

### Signature

`android/app/build.gradle.kts` lit le fichier de propriétés de signature à cet emplacement, par ordre de priorité :

1. la propriété Gradle `-Pparcourses.signing=<chemin>` ;
2. la variable d'environnement `PARCOURSES_ANDROID_SIGNING` ;
3. `~/.config/parcourses/android-signing.properties` par défaut.

- Si le fichier existe, `release` est signée avec la clé d'envoi (configuration `upload`). Un `storeFile` relatif se
  lit depuis le dossier du fichier de propriétés.
- Un chemin donné par l'option ou la variable doit exister : sinon, le build échoue.
- Sans option, sans variable et sans le fichier par défaut (CI, autre poste), `release` est signée avec la clé de
  debug, et Gradle l'annonce : `Parcourses : … introuvable, la release est signée avec la clé de debug`. Ce paquet est
  refusé par Play.
- Les variantes de mesure `benchmarkRelease` et `nonMinifiedRelease`, créées par le plugin Baseline Profile, restent
  signées avec la clé de debug, même quand la clé d'envoi est présente.

`./gradlew :app:signingReport` affiche la configuration et les empreintes de chaque variante. Il n'affiche aucun mot de passe.

### Version

Chaque envoi sur Play doit avoir un `versionCode` **strictement plus grand** que tous ceux déjà envoyés, toutes
pistes confondues. Un numéro refusé ne se réutilise pas.

| Propriété | Défaut |
| --- | --- |
| `-Pparcourses.versionCode=<entier>` | `1` |
| `-Pparcourses.versionName=<texte>` | `0.1.0` |

Le `versionCode` du dernier envoi se lit dans la Play Console, dans l'*Explorateur d'app bundles*.

### Environnement Supabase

La release vise `prod` par défaut (voir `android/README.md`). Sans `parcourses.supabase.prod.url` et
`parcourses.supabase.prod.key` (dans `~/.gradle/gradle.properties`), ni `PARCOURSES_SUPABASE_PROD_URL` et
`PARCOURSES_SUPABASE_PROD_KEY`, l'app construite reste **entièrement locale** et ne synchronise rien. Pour une bêta,
fournir l'URL `https://<ref>.supabase.co` et la clé **publishable** (`sb_publishable_…`) du projet hébergé, jamais
une clé `secret` ou `service_role`.

### Commande

Depuis `android/`, sous le jeton de build partagé (`scripts/build-lock.sh`) :

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
../scripts/build-lock.sh release-android ./gradlew :app:bundleRelease \
  -Pparcourses.versionCode=2 -Pparcourses.versionName=0.1.1
```

L'AAB est écrit dans `android/app/build/outputs/bundle/release/app-release.aab`.

### Vérifier la signature

```sh
keytool -printcert -jarfile app/build/outputs/bundle/release/app-release.aab | grep SHA256
```

On doit retrouver l'empreinte de la clé d'envoi ci-dessus. Si l'empreinte est celle de la clé de debug, le fichier
de propriétés n'a pas été trouvé : relire l'avertissement de Gradle.

On range ensuite une copie de chaque AAB envoyé dans `~/.config/parcourses/builds/`, nommée avec sa version
(`parcourses-<versionName>-<versionCode>.aab`).

## Empreinte pour `assetlinks.json`

Les App Links des invitations (`https://parcourses.hadrien.eu/i/`) sont vérifiés par Android à l'aide de
`site/.well-known/assetlinks.json`, qui liste les empreintes SHA-256 des certificats autorisés. Voir aussi
`docs/site.md`.

Il faut y déclarer l'empreinte de la **clé de signature de l'app**, celle de Google, et **pas celle de la clé
d'envoi** : les APK installés depuis Play ne portent que la signature de Google. On la trouve dans
*Play Console → Intégrité de l'app → Signature de l'app → Certificat de la clé de signature d'application →
Empreinte du certificat SHA-256*. Elle n'existe qu'après le premier envoi d'un AAB.

Ensuite :

1. ajouter cette empreinte à `sha256_cert_fingerprints` dans `site/.well-known/assetlinks.json`, et publier le site ;
2. retirer l'empreinte de debug quand plus aucun test ne passe par un APK de debug (voir `docs/site.md` :
   le mot de passe de la clé de debug est public) ;
3. sur un appareil qui a installé l'app depuis Play :
   `adb shell pm verify-app-links --re-verify fr.parcourses.app`, puis
   `adb shell pm get-app-links fr.parcourses.app`. Le domaine doit être `verified`.

La Play Console propose aussi, sous *Liens profonds*, un `assetlinks.json` prêt à copier.

## fastlane

`android/fastlane/` envoie l'AAB et la fiche Play. La version de fastlane est figée par `android/Gemfile` et
`android/Gemfile.lock`. Installation, depuis `android/` :

```sh
bundle config set --local path vendor/bundle   # gems dans android/vendor/bundle, ignoré par git
bundle install
```

### Compte de service

fastlane se connecte à l'API Google Play Developer avec la clé JSON d'un compte de service. Elle reste hors du dépôt :
`~/.config/parcourses/play-service-account.json` (droits `600`), ou un autre chemin dans `PARCOURSES_PLAY_JSON_KEY`.

Pour la créer, une seule fois :

1. Google Cloud Console : un projet, l'API *Google Play Android Developer API* activée, un compte de service, puis
   *Clés → Ajouter une clé → JSON*. Déposer le fichier dans `~/.config/parcourses/` et faire `chmod 600`.
2. Play Console → *Utilisateurs et autorisations* : inviter l'adresse du compte de service, avec les droits sur
   l'app Parcourses (publier sur les pistes de test, modifier la fiche).
3. Vérifier, sans rien envoyer : `bundle exec fastlane run validate_play_store_json_key`.

### Lanes

| Lane | Ce qu'elle fait | Réseau |
| --- | --- | --- |
| `bundle exec fastlane android check_metadata` | Vérifie la fiche `fr-FR` : fichiers présents, titre ≤ 30, description courte ≤ 80, description complète ≤ 4 000 caractères, notes de version ≤ 500. | Aucun |
| `bundle exec fastlane android internal` | Vérifie que l'AAB est signé par la clé d'envoi, puis l'envoie sur la piste **test interne**, avec ses notes de version. | Google Play |
| `bundle exec fastlane android metadata` | Envoie le titre et les descriptions `fr-FR`, sans AAB ni images. `validate_only:true` fait valider la fiche par Google sans la publier. | Google Play |

Options de `internal` :

- `aab:<chemin>` : un autre AAB que `app/build/outputs/bundle/release/app-release.aab` ;
- `status:draft` : la version reste en brouillon dans la Play Console. C'est obligatoire tant que l'app n'a jamais
  été publiée sur aucune piste : Play refuse alors toute version qui n'est pas un brouillon.

La lane ne construit pas l'AAB : on le construit d'abord avec la commande ci-dessus, sous le jeton de build.

### La fiche

Les textes sont versionnés dans `android/fastlane/metadata/android/fr-FR/` :

| Fichier | Limite |
| --- | --- |
| `title.txt` | 30 caractères |
| `short_description.txt` | 80 caractères |
| `full_description.txt` | 4 000 caractères |
| `changelogs/<versionCode>.txt`, sinon `changelogs/default.txt` | 500 caractères, notes de version envoyées avec l'AAB |

Ils reprennent le ton et les promesses du site (`site/index.html`) et doivent rester cohérents avec la fiche App Store
(`ios/fastlane/metadata/`, #145). Toute promesse sur les données doit concorder avec `docs/play-data-safety.md`. Les
captures d'écran et l'icône de la fiche ne passent pas encore par fastlane : elles se déposent dans la Play Console.

## Premier envoi

La toute première version d'une app se dépose **à la main** dans la Play Console : c'est ce dépôt qui active la
signature d'application Play et crée la clé de signature de l'app. Ensuite :

1. relever l'empreinte de la clé de signature de l'app, et mettre à jour `assetlinks.json` (voir plus haut) ;
2. créer le compte de service, puis envoyer les versions suivantes par `fastlane android internal`, chaque fois avec
   un `versionCode` plus grand.
