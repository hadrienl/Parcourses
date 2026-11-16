# Google Play : section « Sécurité des données »

Lot A12 (#10). Ce document recense, à partir du code de l'app Android au 9 novembre 2026 (`main` à `58b43bb`, plus le lot A12), chaque donnée qui quitte l'appareil. Il propose ensuite les réponses au formulaire de la Play Console.

> **Mise à jour du 16 novembre 2026 (#87, lot 87.8)** : comptes e-mail, prénom, listes partagées entre membres,
> invitations par e-mail (Resend), page web de suppression. Les ajouts sont marqués « (#87) ».
>
> **Statut : proposition, à valider par l'utilisateur.** Rien n'est saisi dans la Play Console. Cinq points restaient à trancher (§5) : la déclaration de la position, la place des visites dans le formulaire, la suppression du compte anonyme, les libellés publiés dans le catalogue et les horodatages lisibles dans le graphe. Les libellés sont traités côté serveur par #69 (§5.4), les horodatages par #70 (§5.5).

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
- **Contacts** (#87) : jamais lus. L'adresse d'une personne invitée est saisie à la main.
- **Signaux temps réel** (#87) : le serveur prévient les membres d'une liste qu'elle a changé, par un canal privé par
  compte. Le signal ne porte que l'identifiant de la liste et le type de changement, jamais de libellé. L'app relit
  ensuite la liste par une requête normale. Rien n'est envoyé par l'app sur ce canal.

## 3. Inventaire de ce qui quitte l'appareil

Toutes les données partent vers le projet Supabase de Parcourses, en HTTPS. La configuration réseau de la release interdit le trafic en clair. Supabase héberge le service pour le compte du développeur : c'est un **prestataire**, pas un partage. Depuis #87, **Resend** envoie pour le compte du développeur les e-mails de connexion (SMTP de l'Auth) et d'invitation (`send-invitation`). Il reçoit l'adresse du destinataire, le contenu de l'e-mail et, pour une invitation, le prénom de la personne qui invite. C'est aussi un prestataire.

| Donnée | Envoyée par | Finalité | Rattachée à l'identifiant ? | Conservation | Éphémère ? |
| --- | --- | --- | --- | --- | --- |
| **Coordonnées** (latitude, longitude) | `nearby_stores(lat, lng, radius_m, max_results)` : à chaque ouverture du choix du magasin si la position est déjà autorisée (et au retour au premier plan si l'autorisation a changé), sinon quand la personne touche « Utiliser ma position » | Proposer le magasin où l'on se trouve | Oui pendant la requête (appel authentifié), mais jamais enregistrées | Aucune : la fonction SQL ne les écrit pas (« La position reçue n'est jamais stockée »). L'appel est un `POST`, les coordonnées sont dans le corps de la requête et non dans l'URL que journalise la passerelle | **Oui** |
| Précision : exacte (`ACCESS_FINE_LOCATION`, `PRIORITY_HIGH_ACCURACY`) ou approximative (`ACCESS_COARSE_LOCATION` seule, `PRIORITY_BALANCED_POWER_ACCURACY`) | | | | | |
| **Recherche de magasin** (texte saisi) | `search_stores(q, max_results)` | Trouver un magasin par nom ou adresse | Oui pendant la requête, jamais enregistrée | Aucune | **Oui** |
| **Identifiant anonyme** (UUID du compte Supabase, jetons de session) | Connexion anonyme au premier lancement (`signInAnonymously`), puis chaque requête | Rattacher les listes et les visites à leur propriétaire, appliquer les droits (RLS) | C'est l'identifiant | Jusqu'à la suppression du compte dans l'app. Un compte sans e-mail est aussi purgé après 365 jours sans activité (§5.3) | Non |
| **Listes et articles** (nom de liste, libellé, quantité, coché ou non, horodatages) | Tables `lists` et `list_items` | Synchroniser les listes et les retrouver après réinstallation sur le même compte | Oui (`owner_id`) | Jusqu'à leur suppression dans l'app (la suppression est envoyée au serveur) | Non |
| **Magasin et heure des visites** (`store_id`, liste, liste triée ou non, début et fin) | Table `visits` | Apprendre l'ordre des rayons du magasin | Oui (`user_id`) | Jusqu'à la suppression du compte, ou 365 jours sans activité (§5.3). Clôture automatique au bout de 2 h d'inactivité (pg_cron) | Non |
| **Articles cochés** (produit ou rayon, heure de la coche, ordre) | Table `checks` | Même finalité : l'ordre des coches est la matière de l'apprentissage | Oui, par la visite | Comme les visites (§5.3) | Non |
| **Catalogue de produits** (libellé de l'article **tel que saisi**, et rayon choisi par le classifieur) | `resolve_products` à la synchro des articles (`ProductResolution` envoie `name = label`) | Relier les articles de tous les utilisateurs au même produit pour apprendre le graphe | Un produit **privé** est rattaché aux comptes qui l'ont saisi (`catalog.product_claims` : libellé et rayon de chacun, jamais lisibles par un client) jusqu'à sa publication. Un produit **publié** n'est rattaché à aucun compte. Un compteur de saisies par compte et par jour (`catalog.product_creations`) limite les abus | Un libellé nouveau reste **privé** : invisible de tous les comptes et absent des instantanés. Il n'est publié (lisible par tous) qu'une fois saisi par **3 comptes distincts**, sous sa forme la plus courante ; ses revendications sont alors supprimées. Sinon elles sont purgées au bout de 180 jours si le compte n'a plus d'article qui y renvoie, ou avec le compte (§5.4). Un produit privé ne garde que la forme normalisée du libellé | Non |
| **Adresse e-mail** (#87, facultative) | « Se connecter » : liaison du compte anonyme (`updateUser`) ou connexion à un compte existant, par un code à 6 chiffres envoyé par e-mail (`signInWithOtp`, `verifyOtp`) | Se connecter, retrouver ses listes sur un autre appareil, recevoir les invitations adressées à cette adresse (`my_invitations`) | Oui (`auth.users.email`) | Jusqu'à la suppression du compte. Un compte e-mail n'est jamais purgé pour inactivité. Le code expire après 15 minutes. Jamais montrée aux autres membres | Non |
| **Prénom** (#87, facultatif) | Écran « Se connecter » ou « Compte » (`profiles.display_name`, 1 à 40 caractères) | Montré aux membres des listes partagées et dans l'objet des e-mails d'invitation envoyés | Oui | Jusqu'à sa modification ou la suppression du compte | Non |
| **Adresse e-mail d'une personne invitée** (#87) | Feuille « Partager la liste » (Edge Function `send-invitation`, RPC `create_invitation`) | Envoyer l'invitation, et la proposer à cette personne quand elle se connecte avec cette adresse | Rattachée à l'invitation et à son auteur | Invitation valable 7 jours, effacée 30 jours après son acceptation, son refus, son annulation ou son expiration (job `sharing-invitations-purge`). Le compteur anti-abus par destinataire ne garde qu'un hachage SHA-256 de l'adresse, 2 jours. Jeton d'invitation conservé haché | Non |
| **Listes partagées** (#87) | Acceptation d'une invitation par le destinataire (`accept_invitation`) | Les membres voient le nom de la liste, ses articles, l'auteur de la dernière modification (`updated_by`) et le prénom des membres. Le propriétaire voit les adresses des invitations en attente | Oui (`list_members`) | Tant que la personne est membre. Si le propriétaire supprime son compte, la liste passe à l'éditeur le plus ancien, sinon au lecteur le plus ancien ; une liste sans membre est supprimée | Non |
| **Pierres tombales** (#87) | Suppression d'une liste ou d'un article | Propager la suppression aux autres appareils et aux membres | Identifiant de l'élément et de sa liste, sans contenu | 30 jours (job `sharing-tombstones-purge`) | Non |
| **Données techniques** : adresse IP, en-têtes HTTP des bibliothèques (version du client, aucun identifiant d'appareil), horodatage | Toute requête | Faire fonctionner le service, journaux de sécurité de Supabase (dont `auth.audit_log_entries`) | Partiellement (journaux d'authentification) | Selon la rétention des journaux Supabase. Les lignes de `auth.audit_log_entries` qui citent le compte sont effacées avec lui (§5.3), et toutes celles de plus de 90 jours chaque nuit (job `accounts-audit-retention`). Sur le projet hébergé, GoTrue n'écrivait pas ce journal en base (constaté le 13 novembre 2026) | Non |

L'app ne déduit aucune position de l'adresse IP. Play n'a pas de type de donnée « adresse IP » ; on la mentionne pour être complet.

**Données dérivées.** Le serveur agrège les visites closes en graphe de voisinage par magasin (`store_edges`, `store_entries`, `store_stats`), puis en publie un instantané (`store_graph_snapshots`). Ce graphe ne contient pas d'identifiant d'utilisateur. Il contient en revanche des dates issues des visites : `last_seen_at` (jour de la dernière visite qui a touché l'arête ou l'entrée) et `store_stats.last_visit_at`, ramenées au jour depuis #70. Depuis #70 (lot 70.1), aucun compte ne peut lire ces tables : les apps reçoivent seulement l'instantané d'un magasin, par la RPC `store_graph_snapshot`. Depuis le lot 70.2, le graphe ne date une visite qu'au jour près : il n'apprend que des journées terminées, et l'instantané, publié une fois par nuit et calculé à minuit, ne dit plus l'heure d'une visite. Seule exception : les poids appris avant 70.2 gardent de petits écarts entre visites anciennes (moins d'un jour), déjà publiés, qui s'effacent avec la décroissance. Depuis le lot 70.3, l'instantané d'un magasin qui n'a qu'un seul contributeur n'est servi qu'à ce contributeur : les autres comptes ne voient ni ses produits ni le jour de ses visites. Il faut au moins deux comptes contributeurs distincts dans les 180 derniers jours pour que l'instantané soit servi à tous (§5.5).

## 4. Réponses proposées au formulaire

### 4.1 Questions générales

| Question | Réponse proposée | Justification |
| --- | --- | --- |
| Votre app collecte-t-elle ou partage-t-elle des types de données utilisateur obligatoires ? | **Oui** | Voir §3 |
| Toutes les données collectées sont-elles chiffrées lors de leur transit ? | **Oui** | HTTPS seulement : `network_security_config` de la release, `usesCleartextTraffic="false"` |
| Proposez-vous un moyen de demander la suppression des données ? | **Oui** (§5.3) | Dans l'app : « À propos », puis « Supprimer mes données… » (68.2, 68.3). Page web : `https://parcourses.hadrien.eu/supprimer-mes-donnees/` (87.8), à saisir dans la Play Console. Elle donne la marche à suivre dans l'app, puis une demande par e-mail pour un compte e-mail |

### 4.2 Types de données

« Partagé » est à **Non** partout. Supabase et Resend sont des prestataires, et le graphe est anonymisé. Les listes partagées entre membres (#87) ne sont pas non plus un partage au sens de Play : la personne choisit elle-même d'inviter quelqu'un et sait que la liste lui sera montrée. C'est à décrire dans la Play Console, sans le déclarer comme partage (à valider, §5.6).

| Catégorie Play | Type | Collecté | Éphémère | Obligatoire ou facultatif | Finalité |
| --- | --- | --- | --- | --- | --- |
| Position | Position exacte | Oui, **proposition §5.1** | Oui | Facultatif : sans autorisation, recherche par nom ou « Continuer sans magasin » | Fonctionnement de l'application |
| Informations personnelles | ID utilisateur | Oui | Non | Obligatoire (créé au premier lancement si le service est joignable) | Fonctionnement de l'application, Gestion du compte |
| Informations personnelles | Adresse e-mail (#87) : celle du compte, et celle d'une personne invitée | Oui | Non | Facultatif : seulement pour se connecter ou partager une liste | Fonctionnement de l'application, Gestion du compte |
| Informations personnelles | Nom (#87) : le prénom | Oui | Non | Facultatif | Fonctionnement de l'application |
| Activité dans les applications | Interactions avec l'application (coches horodatées, visites) | Oui | Non | Obligatoire pour la synchro (rien n'est désactivable aujourd'hui) | Fonctionnement de l'application |
| Activité dans les applications | Historique des recherches dans l'application | Oui | Oui | Facultatif | Fonctionnement de l'application |
| Activité dans les applications | Autres contenus générés par l'utilisateur (listes, libellés, quantités) | Oui | Non | Obligatoire pour la synchro | Fonctionnement de l'application |
| Informations financières | Historique des achats (articles cochés en magasin) | Oui, **à valider** (§5.2) | Non | Obligatoire pour la synchro | Fonctionnement de l'application |

Rien n'est déclaré pour « Analyse », « Publicité ou marketing », « Personnalisation » ni « Communications du développeur ».

**Cohérence avec iOS.** `ios/Parcourses/PrivacyInfo.xcprivacy` déclare `UserID`, `OtherUserContent`, `ProductInteraction`, `PurchaseHistory` et, depuis #87, `EmailAddress` et `Name`. Toutes sont rattachées, sans suivi, pour le fonctionnement de l'app. Il ne déclare aucune position. Le tableau ci-dessus reprend ces six types. Les étiquettes App Store sont consignées dans `docs/app-store-privacy.md`. Il y a deux écarts. La position (§5.1) est à reporter sur iOS (App Store Connect) si la décision change. L'« Historique des recherches » (recherche de magasin) est déclaré ici et pas sur iOS, ce qui peut se justifier : Apple ne compte pas comme collecte une donnée traitée seulement en temps réel. Il faut alors l'écrire dans la déclaration iOS plutôt que de l'aligner sans réfléchir.

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

La règle « Account Deletion Requirement » des [Règles relatives aux données utilisateur](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en) s'applique dès que l'app permet de *"create an account from within your app"*. Elle impose alors une suppression du compte dans l'app **et** sur une page web, dont l'URL est saisie dans la Play Console. La page ne prévoit pas d'exception pour un compte anonyme créé automatiquement. Au moment de cette analyse (lot A12), Parcourses ne proposait aucune suppression du compte ni des visites. C'est fait depuis : voir la décision ci-dessous et l'état au 16 novembre 2026.

Options :

1. Considérer que le compte anonyme, créé sans action de la personne, n'entre pas dans la règle. Répondre « Non » à la question sur la suppression. C'est un risque à l'examen.
2. Ajouter « Supprimer mes données » dans À propos : appel serveur qui supprime le compte, avec effacement en cascade des listes, visites et coches. Ajouter aussi une page web avec la marche à suivre, puis répondre « Oui ». C'est un lot à part, côté serveur (#8) et sur les deux apps.
3. Purger automatiquement les visites et coches au bout de 90 jours. La FAQ accepte le badge si l'on *"automatically initiate deletion or anonymization of collected data within 90 days of collection"*. Cela ne couvre ni le compte ni les listes, mais limite la conservation.

Recommandation : **2**, éventuellement complétée de 3. À faire avant la publication, dans un ticket dédié.

**Décision (#68, 12 novembre 2026)** : option 2, sans l'option 3. À la place de l'option 3, les comptes anonymes inactifs depuis 365 jours sont purgés. Trois lots :

1. **68.1 (fait, serveur)** : la RPC `delete_my_account()` (`…_account_deletion.sql`) supprime le compte de l'appelant, sans paramètre. La cascade efface ses listes et articles, ses visites (dont celles pas encore apprises) et leurs coches, le compteur `catalog.product_creations`, ses revendications de produits privés (`catalog.product_claims`, #69 : son libellé tel que saisi part avec elles ; la forme normalisée d'un produit privé qu'il était seul à avoir saisi part avec la purge nocturne suivante, données du graphe comprises, lot S2 de #69), ses identités, sessions (adresse IP, agent) et jetons. Les lignes du journal d'authentification qui citent le compte sont effacées dans la même transaction. Le graphe agrégé est gardé : il ne contient aucun identifiant, il est daté au jour et réservé aux magasins à plusieurs contributeurs (§5.5). Le job `accounts-purge-inactive` (toutes les heures, 1 000 comptes au plus par passage) supprime de la même façon les comptes anonymes sans activité depuis 365 jours : rien de plus récent dans le compte, ses sessions, ses listes, ses articles ni ses visites. Un compte qui a lié un e-mail n'est jamais purgé. C'est le seul recours de qui a désinstallé l'app, puisqu'un compte anonyme ne peut pas être retrouvé sans elle. Si l'app revient après une purge, elle repart sur un compte neuf et y renvoie ce qu'elle a en local (`AccountRekey`).
2. **68.2 (iOS) et 68.3 (Android), faits** : « Supprimer mes données… » dans À propos, avec confirmation, réseau exigé, puis purge de l'appareil et nouveau compte anonyme.
   - **68.2 (iOS, fait)** : Sur iOS, la purge couvre la base locale (listes, articles, visites, coches, file d'envoi, magasins récents, instantanés, catalogue), la session et le dernier compte connu du Keychain, les curseurs, le cache HTTP et les Live Activities. Aucune donnée n'est renvoyée au nouveau compte, et une suppression interrompue reprend au lancement suivant. Le manifeste `PrivacyInfo.xcprivacy` ne change pas : aucune donnée nouvelle, et les préférences restent propres à l'app (`CA92.1`).
   - **68.3 (Android, fait)** : section « Vos données » d'À propos, confirmation, voile « Suppression… », puis « Vos données ont été supprimées. » sur l'écran Listes vide. Sur l'appareil, tout est effacé : la base Room entière (listes, articles, visites, coches, file d'envoi, magasins récents, instantanés du graphe, catalogue, puis catégories réamorcées), la session chiffrée et le dernier compte connu (vidés, le jeu de clés Tink et la clé du Keystore restent : ils ne contiennent aucune donnée personnelle), les curseurs de synchronisation, les préférences de la Live Update et sa notification. Aucune donnée n'est renvoyée au nouveau compte anonyme. Le drapeau `account_deletion` qui protège la suppression en cours est exclu de la sauvegarde et du transfert d'appareil. Aucun cache HTTP n'est installé : rien d'autre à effacer.
3. **Page web, reportée** : le projet est encore une preuve de concept ; domaine et contact restent à choisir (#68, Q4 et Q5).
4. **Rétention du journal d'authentification (fait, serveur)** : `accounts.purge_audit_log()` (`…_auth_audit_retention.sql`), lancé chaque nuit par le job `accounts-audit-retention`, supprime les lignes de `auth.audit_log_entries` de plus de 90 jours, comptes actifs compris (décision du 13 novembre 2026). Le journal garde l'id du compte et l'adresse IP de chaque connexion ; sur le projet hébergé, GoTrue ne l'écrivait pas en base (0 ligne, constaté le 13 novembre 2026). Par lots de 10 000, 50 lots au plus par nuit.

Un doute hors ligne pendant une suppression (réponse du serveur perdue, app relancée sans réseau) bloque l'app jusqu'au retour du réseau, par décision du 13 novembre 2026.

Réponse au §4.1 : « Oui » quand les lots 68.2, 68.3 et la page web seront livrés. **Tant que la page web n'existe pas, pas de publication sur Google Play** : la règle exige son lien dans la Play Console.

### 5.4 Libellés publiés dans le catalogue

Le libellé saisi librement (« médicament de Paul », « cadeau pour Marie ») part vers `resolve_products`. Jusqu'à #69, quand il était nouveau, il devenait un produit partagé, durable, lisible par tous les comptes et proposé par l'autocomplétion des deux apps. `resolve_products` disait aussi, sans rien créer, si un libellé avait déjà été saisi par quelqu'un.

**Traité par #69, lot S1** (`…_catalog_claims.sql`, détail dans `docs/data-model.md`) :

- un produit naît **privé** : aucun compte ne le lit, pas même son créateur, et il n'apparaît dans aucun instantané du graphe. Le graphe l'apprend quand même ;
- il est **publié** quand 3 comptes distincts l'ont saisi, sous le libellé le plus fréquent et le rayon majoritaire. Un libellé contenant une adresse web, un e-mail ou une suite de 5 chiffres ou plus (téléphone, code) n'est jamais publié ;
- `resolve_products` ne renvoie à chaque compte que son propre libellé et son propre rayon tant que le produit est privé, et répond de la même façon qu'un libellé ait déjà été saisi ou non ;
- les produits déjà en base sont devenus privés, sauf ceux que 3 comptes avaient déjà dans leurs listes. Les appareils effacent les noms qui ne sont plus publiés au téléchargement suivant du catalogue (quotidien), y compris quand plus aucun produit n'est publié (lot apps de #69). L'écran À propos le dit : « Les noms d'articles que vous saisissez restent privés. Un nom ne rejoint le catalogue commun, sans lien avec vous, qu'une fois saisi par au moins trois personnes. »

**Lot S2** (`…_starter_catalog.sql`) : 150 produits courants, aux libellés génériques relus (« Lait », « Pommes de terre », « Papier toilette »…), sont publiés d'emblée : ce ne sont pas des saisies d'utilisateurs. La purge nocturne supprime aussi les produits privés que plus aucun compte n'a (sans revendication, article ni coche), avec ce que le graphe en avait appris : la forme normalisée d'un libellé ne reste pas en base une fois supprimé le dernier compte qui l'avait saisi.

Effet sur le formulaire : la ligne « Autres contenus générés par l'utilisateur » reste **collectée, non partagée**. Un libellé n'est rendu visible aux autres comptes que lorsqu'il est devenu générique (saisi indépendamment par 3 comptes), et il n'est alors rattaché à personne.

Limite qui reste : 3 comptes anonymes se créent sans effort. Quelqu'un qui devine le libellé exact d'un tiers et le saisit depuis 2 comptes **fait publier le produit de ce tiers** : il apprend que le libellé avait été saisi, et les observations de ce tiers dans le graphe sortent ensuite dans les instantanés (sous les seuils de contributeurs de #70, §5.5). Il n'obtient ni la graphie exacte du tiers (à égalité, c'est la forme normalisée qui est publiée) ni son rayon (à égalité, le plus petit identifiant). Il faut deviner le libellé exact, minuscules et accents mis à part. Le durcissement des comptes jetables relève de #47.

### 5.5 Horodatages lisibles dans le graphe

Traité par #70, en trois lots :

1. **70.1 (fait)** : `store_edges`, `store_entries`, `store_stats` et `store_graph_snapshots` ne sont plus lisibles par aucun compte (`…_graph_read_closed.sql`). L'instantané n'est servi que par la RPC `store_graph_snapshot`, magasin par magasin. Le signal « une visite vient d'être apprise » ne se lit plus dans `store_stats`, mis à jour chaque minute. Jusqu'au lot 70.2, il restait visible dans la version de l'instantané, horodatée et republiée au plus une fois par heure.
2. **70.2 (fait)** : dates du graphe arrondies au jour (Europe/Paris), lignes existantes comprises ; une visite n'est apprise qu'après minuit ; instantanés publiés une fois par nuit seulement, calculés à minuit (`…_graph_day_granularity.sql`). L'instantané ne date plus une visite qu'au jour près.
3. **70.3 (fait)** : l'instantané d'un magasin à un seul contributeur n'est servi qu'à ce contributeur ; il faut deux contributeurs distincts dans les 180 derniers jours pour qu'il soit servi à tous (`…_snapshot_min_contributors.sql`). Seuls des nombres de contributeurs sont gardés, jamais leur identité.

**État au 16 novembre 2026 (#87, lot 87.8)** :
- Dans l'app, « À propos », puis « Supprimer mes données… » appelle `delete_my_account()`. C'est fait sur iOS (68.2) et sur Android (68.3), et l'effacement local passe par `LocalDataPurge`.
- Page web : `https://parcourses.hadrien.eu/supprimer-mes-donnees/`, publiée par `site/`. Elle décrit la marche à suivre dans l'app, ce qui est supprimé et ce qui reste : une liste partagée passe à son membre le plus ancien, et le plan commun et les produits publiés restent. Pour un compte e-mail sans l'app, elle propose une demande par e-mail, traitée sous 30 jours. Un compte anonyme sans l'app est purgé après 365 jours.
- Politique de confidentialité : `https://parcourses.hadrien.eu/confidentialite/`. Son URL est à saisir dans la Play Console et dans App Store Connect.
- Les textes de ces deux pages sont **à valider par l'utilisateur** : éditeur, adresse de contact, région d'hébergement Supabase, transferts hors UE.

Limites qui restent, assumées dans la conception de #70. Le seuil protège contre la curiosité passive, **pas contre un attaquant ciblé** : avec un seuil de 2, il suffit d'un seul compte et d'une visite apprise (3 coches) dans le magasin visé pour recevoir l'instantané le lendemain et y retrancher sa propre contribution. Dans un magasin à deux contributeurs, chacun peut de même en partie déduire l'autre. Une même personne qui a plusieurs comptes anonymes (réinstallation, second appareil) compte pour plusieurs contributeurs : rien ne permet de les dédoublonner sans identité. Un produit rare acheté par une seule personne reste visible dans un magasin partagé, s'il est publié : depuis #69, un produit saisi par moins de 3 comptes n'apparaît dans aucun instantané (§5.4). Enfin, les instantanés déjà téléchargés restent sur les appareils. Le seuil se relève par paramètre (`PUBLISH_MIN_CONTRIBUTORS`).

### 5.6 Listes partagées et invitations (#87)

Deux points à valider :

1. **Partage au sens de Play.** Une liste partagée est montrée aux comptes que la personne a elle-même invités. Proposition : ne pas la déclarer comme « partagée », car le transfert vient d'une action explicite de la personne, qui sait à qui la liste sera montrée. Il faut le dire dans la description de la fiche et dans la politique de confidentialité (`/confidentialite/`, faite).
2. **Adresse d'un tiers.** L'adresse d'une personne invitée est une donnée sur quelqu'un qui n'utilise peut-être pas l'app. Proposition : la déclarer sous « Adresse e-mail », avec la finalité « Fonctionnement de l'application ». Elle est conservée au plus 37 jours (7 jours de validité, puis 30 jours) et jamais montrée à d'autres que le propriétaire de la liste.

## 6. Points à revoir si le code change

- Ajouter Crashlytics, un SDK d'analyse ou de publicité : nouvelles déclarations (« Informations et performances de l'application », « Analyse »).
- ~~Ajouter la liaison e-mail~~ : fait (#87, §3 et §4.2).
- ~~Ajouter les listes partagées~~ : fait (#87, §3, §4.2 et §5.6).
- Ajouter les notifications push (hors #87) : jeton d'appareil, nouvelle déclaration.
- Changer de prestataire d'e-mail (Resend) : mettre à jour §3 et la page `/confidentialite/`.
- Ajouter le géorepérage (`ACCESS_BACKGROUND_LOCATION`) : la position n'est plus ponctuelle, déclaration et justification Play à refaire.
- Journaliser les requêtes HTTP : les coordonnées ne seraient plus éphémères. `install(Logging)` reste interdit dans `:core:network`.
