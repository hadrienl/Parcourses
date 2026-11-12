# Google Play : section « Sécurité des données »

Lot A12 (#10). Ce document recense, à partir du code de l'app Android au 9 novembre 2026 (`main` à `58b43bb`, plus le lot A12), chaque donnée qui quitte l'appareil. Il propose ensuite les réponses au formulaire de la Play Console.

> **Statut : proposition, à valider par l'utilisateur.** Rien n'est saisi dans la Play Console. Cinq points restent à trancher (§5) : la déclaration de la position, la place des visites dans le formulaire, la suppression du compte anonyme, les libellés publiés dans le catalogue et les horodatages lisibles dans le graphe.

## 1. Définitions de Google Play

Les citations viennent de l'aide de la Play Console, [« Fournir des informations pour la section Sécurité des données de Google Play »](https://support.google.com/googleplay/android-developer/answer/10787469?hl=fr) ([version anglaise](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)), lue le 9 novembre 2026. Le texte anglais fait foi en cas d'écart.

**Collecte** (section *Data collection* / « Collecte des données ») :

> « Le terme "Collecte" désigne la transmission des données de l'application depuis l'appareil d'un utilisateur. »
>
> *"Collect" means transmitting data from your app off a user's device.*

Ne sont pas de la collecte : les données traitées uniquement sur l'appareil, et celles qui sont chiffrées de bout en bout de façon illisible pour le développeur. Les données pseudonymes, elles, en sont : *"User data collected pseudonymously must be disclosed."*

**Traitement éphémère** (même section, *Ephemeral processing* / « Traitement éphémère ») :

> *Processing data "ephemerally" means accessing and using it while the data is only stored in memory and retained for no longer than necessary to service the specific request in real-time.*

Google donne l'exemple d'une app météo qui envoie la position pour obtenir la météo du lieu, sans la conserver une fois la requête servie. Une donnée traitée de façon éphémère **reste à déclarer dans le formulaire**, mais elle n'est pas affichée sur la fiche Play :

> *User data transmitted off device that is processed ephemerally needs to be included in your form response, but if it meets the standard below, it will **not** be disclosed in your app's Data safety section on Google Play.*

La question du formulaire est : *"Is this data processed ephemerally?"* (« Ces données sont-elles traitées de manière éphémère ? »).

**Types de données « Position »** :

- *Approximate location* (« Position approximative ») : *"User or device physical location to an area greater than or equal to 3 square kilometers, such as the city a user is in, or location provided by Android's ACCESS_COARSE_LOCATION permission."*
- *Precise location* (« Position exacte » dans la version française) : *"User or device physical location within an area less than 3 square kilometers, such as location provided by Android's ACCESS_FINE_LOCATION permission."*

**Partage** (section *Data sharing*) : *"'Sharing' refers to transferring user data collected from your app to a third party."* Ne sont pas du partage : les transferts à un prestataire (*service provider*) qui traite les données pour le compte du développeur et selon ses instructions, les obligations légales, les actions initiées par l'utilisateur, et les données entièrement anonymisées.

## 2. Ce qui ne quitte pas l'appareil

Ces données ne sont pas de la collecte au sens de Play.

- **Coordonnées GPS stockées** : aucune. Elles ne sont écrites ni dans Room, ni dans DataStore, ni dans les journaux (#10 §7). Le client HTTP n'installe aucun journal (`install(Logging)` absent).
- **Sauvegarde** : `android:allowBackup="false"`, et `dataExtractionRules` exclut le fichier de session. Rien ne part vers la sauvegarde Google.
- **Live Update** : la notification et ses données restent sur l'appareil.
- **Télémétrie** : aucune. Pas de Crashlytics, pas de SDK d'analyse ni de publicité (#10 §16 : « rien au MVP »).
- **Identifiants d'appareil** : aucun. Ni Android ID, ni identifiant publicitaire, ni identifiant d'installation Firebase.
- **Sans configuration Supabase** (build sans URL), l'app est entièrement locale et rien ne part.

## 3. Inventaire de ce qui quitte l'appareil

Toutes les données partent vers le projet Supabase de Parcourses, en HTTPS. La configuration réseau de la release interdit le trafic en clair. Supabase héberge le service pour le compte du développeur : c'est un **prestataire**, pas un partage.

| Donnée | Envoyée par | Finalité | Rattachée à l'identifiant ? | Conservation | Éphémère ? |
| --- | --- | --- | --- | --- | --- |
| **Coordonnées** (latitude, longitude) | `nearby_stores(lat, lng, radius_m, max_results)` : à chaque ouverture du choix du magasin si la position est déjà autorisée (et au retour au premier plan si l'autorisation a changé), sinon quand la personne touche « Utiliser ma position » | Proposer le magasin où l'on se trouve | Oui pendant la requête (appel authentifié), mais jamais enregistrées | Aucune : la fonction SQL ne les écrit pas (« La position reçue n'est jamais stockée »). L'appel est un `POST`, les coordonnées sont dans le corps de la requête et non dans l'URL que journalise la passerelle | **Oui** |
| Précision : exacte (`ACCESS_FINE_LOCATION`, `PRIORITY_HIGH_ACCURACY`) ou approximative (`ACCESS_COARSE_LOCATION` seule, `PRIORITY_BALANCED_POWER_ACCURACY`) | | | | | |
| **Recherche de magasin** (texte saisi) | `search_stores(q, max_results)` | Trouver un magasin par nom ou adresse | Oui pendant la requête, jamais enregistrée | Aucune | **Oui** |
| **Identifiant anonyme** (UUID du compte Supabase, jetons de session) | Connexion anonyme au premier lancement (`signInAnonymously`), puis chaque requête | Rattacher les listes et les visites à leur propriétaire, appliquer les droits (RLS) | C'est l'identifiant | Tant que le compte existe. Aucun nom ni e-mail | Non |
| **Listes et articles** (nom de liste, libellé, quantité, coché ou non, horodatages) | Tables `lists` et `list_items` | Synchroniser les listes et les retrouver après réinstallation sur le même compte | Oui (`owner_id`) | Jusqu'à leur suppression dans l'app (la suppression est envoyée au serveur) | Non |
| **Magasin et heure des visites** (`store_id`, liste, liste triée ou non, début et fin) | Table `visits` | Apprendre l'ordre des rayons du magasin | Oui (`user_id`) | Sans limite à ce jour. Clôture automatique au bout de 2 h d'inactivité (pg_cron) | Non |
| **Articles cochés** (produit ou rayon, heure de la coche, ordre) | Table `checks` | Même finalité : l'ordre des coches est la matière de l'apprentissage | Oui, par la visite | Sans limite à ce jour | Non |
| **Catalogue de produits** (libellé de l'article **tel que saisi**, et rayon choisi par le classifieur) | `resolve_products` à la synchro des articles (`ProductResolution` envoie `name = label`) | Relier les articles de tous les utilisateurs au même produit pour apprendre le graphe | Le produit créé n'est pas rattaché au compte. Seul un compteur de créations par compte et par jour l'est (`catalog.product_creations`), pour limiter les abus | Durable. Un libellé nouveau est enregistré tel quel (rogné) dans `products.name`, **lisible par tous les comptes** (§5.4) | Non |
| **Données techniques** : adresse IP, en-têtes HTTP des bibliothèques (version du client, aucun identifiant d'appareil), horodatage | Toute requête | Faire fonctionner le service, journaux de sécurité de Supabase (dont `auth.audit_log_entries`) | Partiellement (journaux d'authentification) | Selon la rétention des journaux Supabase | Non |

L'app ne déduit aucune position de l'adresse IP. Play n'a pas de type de donnée « adresse IP » ; on la mentionne pour être complet.

**Données dérivées.** Le serveur agrège les visites closes en graphe de voisinage par magasin (`store_edges`, `store_entries`, `store_stats`), puis en publie un instantané (`store_graph_snapshots`). Ce graphe ne contient pas d'identifiant d'utilisateur. Il contient en revanche des dates issues des visites : `last_seen_at` (jour de la dernière visite qui a touché l'arête ou l'entrée) et `store_stats.last_visit_at`, ramenées au jour depuis #70. Depuis #70 (lot 70.1), aucun compte ne peut lire ces tables : les apps reçoivent seulement l'instantané d'un magasin, par la RPC `store_graph_snapshot`. Depuis le lot 70.2, le graphe ne date une visite qu'au jour près : il n'apprend que des journées terminées, et l'instantané, publié une fois par nuit et calculé à minuit, ne dit plus l'heure d'une visite. Seule exception : les poids appris avant 70.2 gardent de petits écarts entre visites anciennes (moins d'un jour), déjà publiés, qui s'effacent avec la décroissance. Il révèle encore les produits d'un magasin à un seul contributeur : le lot 70.3 (instantané servi à ce seul contributeur) ferme ce point (§5.5).

## 4. Réponses proposées au formulaire

### 4.1 Questions générales

| Question | Réponse proposée | Justification |
| --- | --- | --- |
| Votre app collecte-t-elle ou partage-t-elle des types de données utilisateur obligatoires ? | **Oui** | Voir §3 |
| Toutes les données collectées sont-elles chiffrées lors de leur transit ? | **Oui** | HTTPS seulement : `network_security_config` de la release, `usesCleartextTraffic="false"` |
| Proposez-vous un moyen de demander la suppression des données ? | **À trancher** (§5.3) | Aujourd'hui, l'app supprime les listes mais pas le compte, ni les visites |

### 4.2 Types de données

« Partagé » est à **Non** partout : Supabase est un prestataire, et le graphe est anonymisé.

| Catégorie Play | Type | Collecté | Éphémère | Obligatoire ou facultatif | Finalité |
| --- | --- | --- | --- | --- | --- |
| Position | Position exacte | Oui, **proposition §5.1** | Oui | Facultatif : sans autorisation, recherche par nom ou « Continuer sans magasin » | Fonctionnement de l'application |
| Informations personnelles | ID utilisateur | Oui | Non | Obligatoire (créé au premier lancement si le service est joignable) | Fonctionnement de l'application, Gestion du compte |
| Activité dans les applications | Interactions avec l'application (coches horodatées, visites) | Oui | Non | Obligatoire pour la synchro (rien n'est désactivable aujourd'hui) | Fonctionnement de l'application |
| Activité dans les applications | Historique des recherches dans l'application | Oui | Oui | Facultatif | Fonctionnement de l'application |
| Activité dans les applications | Autres contenus générés par l'utilisateur (listes, libellés, quantités) | Oui | Non | Obligatoire pour la synchro | Fonctionnement de l'application |
| Informations financières | Historique des achats (articles cochés en magasin) | Oui, **à valider** (§5.2) | Non | Obligatoire pour la synchro | Fonctionnement de l'application |

Rien n'est déclaré pour « Analyse », « Publicité ou marketing », « Personnalisation » ni « Communications du développeur ».

**Cohérence avec iOS.** `ios/Parcourses/PrivacyInfo.xcprivacy` déclare `UserID`, `OtherUserContent`, `ProductInteraction` et `PurchaseHistory`, toutes rattachées, sans suivi, pour le fonctionnement de l'app. Il ne déclare aucune position. Le tableau ci-dessus reprend ces quatre types. Il y a deux écarts. La position (§5.1) est à reporter sur iOS (App Store Connect) si la décision change. L'« Historique des recherches » (recherche de magasin) est déclaré ici et pas sur iOS, ce qui peut se justifier : Apple ne compte pas comme collecte une donnée traitée seulement en temps réel. Il faut alors l'écrire dans la déclaration iOS plutôt que de l'aligner sans réfléchir.

## 5. Décisions à prendre par l'utilisateur

### 5.1 Position GPS

Les coordonnées partent vers le serveur, donc c'est de la **collecte**. Elles ne sont pas conservées, donc le traitement est **éphémère**. Avec `ACCESS_FINE_LOCATION`, elles sont exactes : bien moins de 3 km².

| Option | Ce qu'on déclare | Pour | Contre |
| --- | --- | --- | --- |
| **A. Position exacte, collectée, éphémère** (recommandation de la coordination) | Position exacte : collectée, traitée de façon éphémère, facultative, fonctionnement de l'app, non partagée | Conforme à la règle (une donnée éphémère doit figurer dans le formulaire) ; Play ne l'affiche pas sur la fiche ; cohérent avec la permission `ACCESS_FINE_LOCATION` que Play voit dans le manifeste | Aucun |
| B. Ne rien déclarer | Rien sous « Position » | Formulaire plus court | **Non conforme** : Google demande d'inclure dans le formulaire les données traitées de façon éphémère (citation du §1). Le manifeste demande `ACCESS_FINE_LOCATION` : l'incohérence est visible à l'examen |
| C. Position approximative seulement | Position approximative, mêmes réponses | Plus rassurant sur la fiche | **Inexact en l'état** : avec l'autorisation exacte, les coordonnées envoyées le sont aussi. Il faudrait arrondir les coordonnées avant l'envoi (une maille d'au moins 3 km²), ce qui dégraderait la proposition du magasin le plus proche, ou ne demander que `ACCESS_COARSE_LOCATION` |

**Proposition, à valider par l'utilisateur : option A.**

Complément possible à A : quand la personne n'accorde que la position approximative, ce sont des coordonnées approximatives qui partent. Cocher aussi « Position approximative », avec les mêmes réponses, décrit exactement les deux cas sans rien changer à l'affichage sur Play, puisque le traitement est éphémère.

### 5.2 Les visites sont-elles une donnée de position ?

Une visite enregistre **dans quel magasin** la personne a fait ses courses et **à quelle heure**, rattaché à son identifiant et conservé sans limite. Un magasin est un lieu physique précis. Le choix d'un magasin n'est pas une lecture du GPS : la personne peut le chercher par son nom. Mais on peut soutenir que Play y verra une position exacte **conservée**, donc non éphémère.

- **Lecture retenue ici** : le magasin est une saisie de la personne, déclarée sous « Interactions avec l'application » et « Historique des achats ». L'option A reste « éphémère ».
- **Lecture prudente** : déclarer aussi la position exacte comme **non éphémère**. Play l'affichera alors sur la fiche (« Position »), pour le fonctionnement de l'app.

À trancher. Si l'on garde la lecture retenue, la fiche ne mentionnera pas la position, alors que le texte de confidentialité de l'app dit bien que Parcourses enregistre « les magasins où vous faites vos courses, l'heure de vos visites » (`about_privacy_data`).

### 5.3 Suppression du compte anonyme

La règle « Account Deletion Requirement » des [Règles relatives aux données utilisateur](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en) s'applique dès que l'app permet de *"create an account from within your app"*. Elle impose alors une suppression du compte dans l'app **et** sur une page web, dont l'URL est saisie dans la Play Console. La page ne prévoit pas d'exception pour un compte anonyme créé automatiquement. Aujourd'hui, Parcourses ne propose aucune suppression du compte ni des visites.

Options :

1. Considérer que le compte anonyme, créé sans action de la personne, n'entre pas dans la règle. Répondre « Non » à la question sur la suppression. C'est un risque à l'examen.
2. Ajouter « Supprimer mes données » dans À propos : appel serveur qui supprime le compte, avec effacement en cascade des listes, visites et coches. Ajouter aussi une page web avec la marche à suivre, puis répondre « Oui ». C'est un lot à part, côté serveur (#8) et sur les deux apps.
3. Purger automatiquement les visites et coches au bout de 90 jours. La FAQ accepte le badge si l'on *"automatically initiate deletion or anonymization of collected data within 90 days of collection"*. Cela ne couvre ni le compte ni les listes, mais limite la conservation.

Recommandation : **2**, éventuellement complétée de 3. À faire avant la publication, dans un ticket dédié.

### 5.4 Libellés publiés dans le catalogue

Le libellé saisi librement (« médicament de Paul », « cadeau pour Marie ») part tel quel vers `resolve_products`. Quand il est nouveau, il devient un produit partagé, durable et lisible par tous les comptes. Il n'est pas rattaché au compte, mais il peut contenir une donnée personnelle.

Options :

1. Ne publier que la forme normalisée, voire ne créer un produit qu'à partir de plusieurs occurrences indépendantes.
2. Ne pas exposer `products.name` aux autres comptes : les apps n'en ont besoin que pour leurs propres articles.
3. Garder le fonctionnement actuel et le décrire comme partage initié par l'utilisateur.

Recommandation : 1 ou 2, dans un ticket serveur (#8). La déclaration Play de la ligne « Autres contenus générés par l'utilisateur » en dépend.

### 5.5 Horodatages lisibles dans le graphe

Traité par #70, en trois lots :

1. **70.1 (fait)** : `store_edges`, `store_entries`, `store_stats` et `store_graph_snapshots` ne sont plus lisibles par aucun compte (`…_graph_read_closed.sql`). L'instantané n'est servi que par la RPC `store_graph_snapshot`, magasin par magasin. Le signal « une visite vient d'être apprise » ne se lit plus dans `store_stats`, mis à jour chaque minute. Jusqu'au lot 70.2, il restait visible dans la version de l'instantané, horodatée et republiée au plus une fois par heure.
2. **70.2 (fait)** : dates du graphe arrondies au jour (Europe/Paris), lignes existantes comprises ; une visite n'est apprise qu'après minuit ; instantanés publiés une fois par nuit seulement, calculés à minuit (`…_graph_day_granularity.sql`). L'instantané ne date plus une visite qu'au jour près.
3. **70.3 (à venir)** : l'instantané d'un magasin à un seul contributeur n'est servi qu'à ce contributeur.

Tant que 70.3 n'est pas livré, l'argument « données anonymisées, donc rien de partagé » reste fragile pour les magasins à un seul contributeur : l'instantané donne ses produits et le jour de ses visites.

## 6. Points à revoir si le code change

- Ajouter Crashlytics, un SDK d'analyse ou de publicité : nouvelles déclarations (« Informations et performances de l'application », « Analyse »).
- Ajouter la liaison e-mail (hors MVP) : « Adresse e-mail », collectée et rattachée, pour la gestion du compte.
- Ajouter les listes partagées : les libellés deviennent visibles par d'autres comptes (action initiée par l'utilisateur, à décrire).
- Ajouter le géorepérage (`ACCESS_BACKGROUND_LOCATION`) : la position n'est plus ponctuelle, déclaration et justification Play à refaire.
- Journaliser les requêtes HTTP : les coordonnées ne seraient plus éphémères. `install(Logging)` reste interdit dans `:core:network`.
