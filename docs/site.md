# Site parcourses.hadrien.eu et liens d'invitation (#87, lot 87.7)

Le site statique `site/` est publié sur GitHub Pages, sous le domaine `parcourses.hadrien.eu`. Le CNAME DNS pointe
déjà vers `hadrienl.github.io`. Le site sert trois choses :

| Chemin | Rôle |
| --- | --- |
| `/i/#<jeton>` | Page d'une invitation quand l'app n'est pas installée : trois étapes, puis « Déjà installée ? Ouvrir dans l'app » (`parcourses://invitation#<jeton>`). Elle est statique et ne fait aucun appel réseau. Le jeton reste dans le fragment : il n'est jamais envoyé à l'hébergeur. |
| `/.well-known/apple-app-site-association` | Liens universels iOS : `QMJKZ67Z3H.app.parcourses`, chemin `/i/*`. |
| `/.well-known/assetlinks.json` | App Links Android : `fr.parcourses.app` et les empreintes SHA-256 des certificats de signature. |

`scripts/check-site.ts` vérifie le site à chaque PR (workflow `pages`) :
- le CNAME, et `.nojekyll` (utile seulement si le site était un jour publié depuis une branche : publié par Actions,
  Jekyll ne tourne pas, et c'est `include-hidden-files` de l'artefact qui fait publier `.well-known/`) ;
- la forme de l'AASA et de `assetlinks.json`, et leur accord avec `APP_BUNDLE_ID` et `applicationId` ;
- aucune ressource distante, avec une CSP `default-src 'none'` ;
- la règle du jeton, comparée au vecteur `shared/test-vectors/sharing/001`.

## Mise en place, une fois

Ces réglages sont à faire dans le dépôt GitHub, par son propriétaire :

1. *Settings → Pages* : choisir la source **GitHub Actions**.
2. Domaine personnalisé `parcourses.hadrien.eu`, puis « Enforce HTTPS » dès que le certificat est émis. Avec une
   publication par Actions, le fichier `site/CNAME` ne suffit pas : le domaine se règle aussi dans *Settings*.
3. Lancer le workflow `pages` (*Actions → pages → Run workflow*), ou pousser sur `main` une modification de `site/`.
4. Vérifier :
   - `curl -sI https://parcourses.hadrien.eu/.well-known/apple-app-site-association` répond 200 ;
   - `curl -s https://parcourses.hadrien.eu/.well-known/assetlinks.json` renvoie le JSON ;
   - l'outil de Google
     (`https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://parcourses.hadrien.eu&relation=delegate_permission/common.handle_all_urls`)
     liste `fr.parcourses.app`.

## Empreintes Android

`assetlinks.json` ne contient pour l'instant que l'empreinte du certificat de **debug** de la machine de
développement : la release est encore signée avec la clé de debug (voir `android/app/build.gradle.kts`). Cette clé a un mot de passe
connu : si `~/.android/debug.keystore` fuyait, une autre app `fr.parcourses.app` signée avec elle ouvrirait les liens
`/i/`. Les builds d'une autre machine ou de la CI, eux, ne sont pas vérifiés. Il faut donc passer à la clé d'upload
Play dès que possible, puis retirer l'empreinte de debug. Quand
l'app passera sur Google Play, il faudra ajouter l'empreinte de la **clé de signature de l'app**. On la trouve dans
*Play Console → Intégrité de l'app → Signature de l'app*. On peut garder l'empreinte de debug pour les builds locaux.

Pour lire une empreinte :

```sh
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android | grep SHA256
```

## Déploiement de `send-invitation`

C'est l'utilisateur qui le lance, jamais un agent :

```sh
scripts/deploy-send-invitation.sh --dry-run   # affiche ce qui serait fait
scripts/deploy-send-invitation.sh
```

Le script lit `~/.config/parcourses/supabase.env`, qui doit contenir `SUPABASE_PROJECT_REF` et `RESEND_API_KEY`. La
CLI doit être connectée (`supabase login` ou `SUPABASE_ACCESS_TOKEN`). Le script pose ensuite trois secrets :

- `RESEND_API_KEY` ;
- `INVITATION_FROM`, par défaut `Parcourses <noreply@parcourses.hadrien.eu>` ;
- `INVITATION_BASE_URL=https://parcourses.hadrien.eu/i/`, **seulement si la page répond déjà**. Si elle ne répond
  pas, la valeur en place ne change pas. `--scheme-links` la retire, et les liens repassent en
  `parcourses://invitation#<jeton>`.

Il déploie la fonction avec `--no-verify-jwt`, puis vérifie qu'elle répond 405 à un GET et 401 à un POST sans JWT.
Les secrets ne sont ni affichés ni passés en argument : ils transitent par un fichier temporaire en mode 600.

Le domaine d'envoi `parcourses.hadrien.eu` doit être vérifié chez Resend (SPF, DKIM), comme pour le SMTP de l'Auth
(`docs/hosted-supabase.md`). Laisser le **suivi des clics de Resend désactivé** : il réécrirait le lien, et le jeton
qu'il porte dans son fragment.

La page `/i/` retire le jeton de l'adresse affichée et de l'historique du navigateur (`history.replaceState`) dès
qu'elle l'a lu. Elle masque « Ouvrir dans l'app » tant que le JavaScript n'a pas trouvé de jeton valide.

## Apps

- **iOS** : l'entitlement `com.apple.developer.associated-domains` contient `applinks:parcourses.hadrien.eu`, et
  `ParcoursesInvitationHost = parcourses.hadrien.eu`.
- **Android** : un `intent-filter` avec `android:autoVerify="true"` (https, hôte `parcourses.hadrien.eu`,
  `pathPrefix="/i/"`), et `parcourses.invitationHost=parcourses.hadrien.eu`.

Ces réglages viennent dans les PR des apps du lot 87.7. Tant qu'ils ne sont pas publiés, un lien https ouvre la page
`/i/`, et son bouton « Ouvrir dans l'app » passe par le schéma.
