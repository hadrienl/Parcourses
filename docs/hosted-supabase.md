# Projet Supabase hébergé : ce que `config.toml` n'applique pas

`supabase/config.toml` ne règle que la pile **locale** (`supabase start`). Sur le projet hébergé, les migrations passent
par `supabase db push`, mais **l'Auth, les modèles d'e-mail et les hooks ne suivent pas** : ils se règlent par l'API de
gestion ou par le tableau de bord. Si on l'oublie, l'hébergé garde ses valeurs par défaut. C'est ce qui s'est passé
pour #87 : un lien magique vers `localhost` au lieu du code, un code à 8 chiffres au lieu de 6, et aucun hook
`before_user_created`.

## Après une modification de l'Auth, lancer `scripts/hosted-auth-config.py`

Cela concerne toute modification de `[auth…]` dans `supabase/config.toml`, et de `supabase/templates/`. Il faut Python
3.11 ou plus (`tomllib`) ; le `/usr/bin/python3` de macOS est trop ancien.

```sh
export SUPABASE_ACCESS_TOKEN=…   # https://supabase.com/dashboard/account/tokens, jamais commité
export SUPABASE_PROJECT_REF=…

scripts/hosted-auth-config.py            # --check : compare l'hébergé au dépôt, n'écrit rien (sortie 1 si écart)
scripts/hosted-auth-config.py --apply    # pousse les seuls écarts, groupe par groupe, puis relit
scripts/hosted-auth-config.py --plan     # réglages voulus, sans réseau
```

Le script est idempotent : un second `--apply` ne pousse rien. Il travaille en **trois groupes**, chacun par son propre
`PATCH` :

1. **auth**, toujours poussé. C'est la liste blanche `PUSHED` du script :

   | Hébergé (API de gestion) | Dépôt (`config.toml`) |
   | --- | --- |
   | `mailer_otp_length`, `mailer_otp_exp` | `auth.email.otp_length`, `auth.email.otp_expiry` |
   | `hook_before_user_created_enabled`, `hook_before_user_created_uri` | `auth.hook.before_user_created` |
   | `external_email_enabled`, `disable_signup`, `external_anonymous_users_enabled` | `auth.email.enable_signup`, `auth.enable_signup` (inversé), `auth.enable_anonymous_sign_ins` |
   | `mailer_autoconfirm`, `mailer_secure_email_change_enabled` | `auth.email.enable_confirmations` (inversé), `auth.email.double_confirm_changes` |

2. **smtp**, seulement si les variables `SMTP_*` sont définies (voir plus bas).
3. **templates** : les objets et les modèles `magic_link`, `confirmation`, `email_change` et `recovery`
   (`auth.email.template.*`, `supabase/templates/code.html`).

   **L'hébergé les refuse sans SMTP personnalisé** : `400 entitlement_required, feature auth.email_templates`, « configure
   a custom SMTP provider ». Sans SMTP, `--apply` pousse quand même le groupe auth, laisse les modèles en attente, le dit,
   et sort en **3**. Le hook et la longueur du code sont actifs dès le groupe auth, mais **les modèles par défaut ne
   portent qu'un lien** (`{{ .ConfirmationURL }}` : `https://<ref>.supabase.co/auth/v1/verify…`, qui redirige vers
   `site_url`) et pas le code : la connexion par code des apps ne
   marche sur l'hébergé qu'une fois les modèles poussés, donc avec un SMTP personnalisé.

Codes de sortie :

- 0 : à jour, ou appliqué et relu conforme ;
- 1 : écarts en `--check`, ou relecture non conforme ;
- 2 : erreur d'usage ou d'API (relancer : un `PATCH` a pu passer avant l'erreur) ;
- 3 : appliqué, sauf les modèles, qui attendent un SMTP (en `--check` aussi, quand seuls les modèles diffèrent et
  qu'aucun SMTP n'est configuré ni fourni).

### SMTP personnalisé

Le SMTP ne vient **que de l'environnement**, jamais de `config.toml`. Les valeurs ne sont jamais affichées. Pour un
écart, seuls les noms des champs sont montrés, et les messages d'erreur de l'API sont nettoyés du jeton et des
secrets. Le mot de passe n'est jamais relu ni comparé : il est envoyé quand le SMTP est absent de l'hébergé ou quand
un autre champ change, ou sur demande avec `--rotate-smtp-pass`.

| Variable | Brevo (proposé) | Resend |
| --- | --- | --- |
| `SMTP_HOST` | `smtp-relay.brevo.com` | `smtp.resend.com` |
| `SMTP_PORT` | `587` | `465` |
| `SMTP_USER` | identifiant SMTP du compte Brevo | `resend` |
| `SMTP_PASS` | clé SMTP Brevo | clé d'API Resend |
| `SMTP_ADMIN_EMAIL` | adresse d'expédition, d'un domaine vérifié chez le fournisseur | idem |
| `SMTP_SENDER_NAME` | facultatif, `Parcourses` par défaut (`auth.email.smtp.sender_name`) | idem |

```sh
SMTP_HOST=smtp-relay.brevo.com SMTP_PORT=587 SMTP_USER=… SMTP_PASS=… SMTP_ADMIN_EMAIL=… \
  scripts/hosted-auth-config.py --apply
```

Pour passer d'un fournisseur à l'autre, il suffit de relancer `--apply` avec les nouvelles variables. Les variables
incomplètes sont refusées : le script nomme celles qui manquent.

**Jamais poussés** :

- `site_url` et les URL de redirection : celles du dépôt visent `127.0.0.1` ;
- le SMTP de `config.toml` : désactivé en local ; seul son `sender_name` sert de valeur par défaut à `SMTP_SENDER_NAME` ;
- les limites de débit et `max_frequency` : valeurs de test locales, plus permissives.

Les tests du script tournent en CI (`supabase`), sans réseau : `python3 scripts/test_hosted_auth_config.py`.

## Ordre de mise en production

1. `supabase db push` : les migrations, dont la fonction du hook (`accounts.before_user_created`), qui doit exister
   avant que le hook soit activé.
2. `scripts/hosted-auth-config.py --apply` : le groupe auth (longueur et durée du code, hook), même sans SMTP
   (sortie 3). À ce stade, les e-mails portent encore le lien par défaut et pas le code.
3. SMTP : créer le compte chez le fournisseur et vérifier le domaine d'expédition, puis relancer `--apply` avec les
   variables `SMTP_*`. Le script pousse alors le SMTP, puis les modèles. Sans SMTP personnalisé, l'hébergé n'envoie
   qu'aux membres de l'organisation, avec un quota très bas.
4. Edge Functions : `supabase functions deploy send-invitation`, avec ses secrets (`RESEND_API_KEY`,
   `INVITATION_FROM`, et plus tard `INVITATION_BASE_URL`). Avec Brevo, la fonction n'a pas encore de chemin d'envoi :
   elle répond `sent = false`, et l'app propose « Copier le lien ».
   Puis `supabase functions deploy notify-inactive-accounts` et ses secrets, et les deux secrets de Vault : voir
   « Purge des comptes e-mail inactifs » plus bas.
5. Vérifier :
   - `scripts/hosted-auth-config.py` doit répondre « à jour ». La relecture porte sur la configuration enregistrée,
     et l'Auth redémarre ensuite en quelques instants.
   - Lier une adresse à un compte anonyme depuis l'app (« Se connecter ») : l'e-mail doit porter un code à 6 chiffres.
     Une connexion directe avec une adresse inconnue est refusée par le hook `before_user_created` : c'est voulu.

## Suppression d'un compte sur demande (page `/supprimer-mes-donnees/`)

La page web promet de supprimer, sur demande par e-mail, le compte e-mail d'une personne qui n'a plus l'app. La
procédure :

1. Vérifier que la demande vient bien de l'adresse du compte : répondre à cette adresse et attendre la confirmation.
   Une demande venue d'une autre adresse ne suffit pas.
2. Retrouver le compte : `select id from auth.users where email = '<adresse en minuscules>';` (éditeur SQL du projet).
3. Supprimer : `select accounts.delete_account('<id>');`.
   - La fonction fait exactement ce que fait « Supprimer mes données » dans l'app (`delete_my_account`) : les listes
     partagées passent à l'éditeur le plus ancien, sinon au lecteur le plus ancien, et le journal d'authentification
     est effacé.
   - Elle est réservée au rôle `postgres`.
   - **Ne pas supprimer l'utilisateur depuis le tableau de bord** : ses listes partagées seraient effacées au lieu
     d'être confiées à un membre, et son journal resterait.
4. Confirmer la suppression par e-mail, dans les 30 jours suivant la demande.

Un compte anonyme ne peut pas être retrouvé sans l'app. La purge des comptes inactifs le supprime après 365 jours.

## Purge des comptes e-mail inactifs (#114)

Un compte e-mail inactif depuis 3 ans est supprimé, après un e-mail de prévenance envoyé au moins 30 jours avant
(`…_inactive_email_accounts.sql`). Le job pg_cron `accounts-inactivity` (05:23 UTC) fait les suppressions dues, puis
appelle l'Edge Function `notify-inactive-accounts` par `pg_net`. La fonction envoie les prévenances par Resend.

Sans les secrets ci-dessous, les suppressions tournent quand même, mais aucune prévenance ne part. Aucun compte n'est
alors supprimé : la suppression exige une prévenance envoyée.

1. **Migration.** `supabase db push`. Elle active l'extension `pg_net` et planifie le job.
2. **Secret partagé.** Le générer une fois, par exemple avec `openssl rand -hex 32`, et le garder hors du dépôt.
3. **Edge Function.**

   ```sh
   supabase secrets set INACTIVITY_NOTICE_SECRET=<secret partagé>
   supabase functions deploy notify-inactive-accounts --use-api
   ```

   - La fonction réutilise `RESEND_API_KEY` et `INVITATION_FROM` (`Parcourses <noreply@parcourses.hadrien.eu>`), déjà
     posés pour `send-invitation`.
   - `SUPABASE_URL` et la clé secrète sont fournis par la plateforme. La fonction lit d'abord `SUPABASE_SECRET_KEYS`
     (`default`), puis la clé historique `SUPABASE_SERVICE_ROLE_KEY` : elle continue de marcher quand les clés
     historiques sont coupées (fin 2026). `send-invitation` fait de même avec `SUPABASE_PUBLISHABLE_KEYS`
     (`functions/_shared/keys.ts`).
   - `verify_jwt = false` vient de `config.toml` : pg_cron n'envoie pas de JWT, et le secret partagé est le seul accès.
   - `send-invitation` importe désormais `functions/_shared/`. La redéployer avec `scripts/deploy-send-invitation.sh`
     (`--use-api`, qui suit les imports relatifs). Le 405 au GET que le script vérifie prouve que la fonction démarre,
     donc que `_shared` a été empaqueté. Faire ensuite une invitation depuis l'app.
4. **Vault.** Dans l'éditeur SQL du projet :

   ```sql
   select vault.create_secret('https://<ref>.supabase.co/functions/v1/notify-inactive-accounts', 'inactivity_notice_url');
   select vault.create_secret('<secret partagé>', 'inactivity_notice_secret');
   ```

   Pour changer le secret : `vault.update_secret` sur la ligne existante, puis `supabase secrets set` avec la même
   valeur.
5. **Vérifier.**
   - Lancer `select accounts.request_inactivity_notices();`. Il doit répondre `true`.
   - Une minute plus tard, `select status_code, content from net._http_response order by created desc limit 1;`
     doit donner `200` et `{"sent":0,"failed":0}` tant qu'aucun compte n'a 35 mois.
   - Un `401` signale un secret différent entre Vault et la fonction. Un `500` (`misconfigured`) signale un secret
     manquant côté fonction.

Fonctionnement, pour le suivi :

- **Prévenance.** Un compte est prévenu à 35 mois d'inactivité. Sa date de suppression est le lendemain, à minuit
  (heure de Paris), de la plus tardive de deux dates : 3 ans d'inactivité, ou 30 jours après l'envoi.
  L'e-mail donne cette date.
- **Envoi refusé.** Si Resend refuse ou si le réseau échoue, la prévenance n'est pas confirmée. Elle est retentée le
  lendemain, et la suppression attend. Une adresse qui rebondit après acceptation par Resend compte comme prévenue.
- **Annulation.** Toute activité après la prévenance l'annule : ouverture de l'app (jeton rafraîchi), connexion,
  liste ou article écrit, visite.
- **Journal.** Chaque passage écrit une ligne `graph.runs` (`kind = 'purge_accounts'`, `detail.scope = 'email'`). La
  ligne donne le nombre de comptes supprimés (`claimed`), de prévenances annulées (`skipped`) et d'échecs (`failed`).
  `detail.pending` compte les prévenances pas encore envoyées, et `detail.stalled` celles qui ont échoué au moins trois
  fois. Un `stalled` qui grandit signale une clé Resend révoquée ou une adresse toujours refusée : ces comptes sont
  gardés tant que la prévenance n'est pas partie. À surveiller :
  `select finished_at, claimed, skipped, failed, detail from graph.runs where detail ->> 'scope' = 'email' order by id desc limit 7;`.
- **État courant.** `select count(*) filter (where notified_at is null) as en_attente, count(*) filter (where
  notified_at is not null) as prevenus from accounts.inactivity_notices;`.

## Recalcul complet du graphe et purge (#29)

Rien à configurer : `supabase db push` crée la file `graph.rebuild_jobs` et les deux jobs pg_cron, `graph-rebuild`
(chaque minute, sans effet sans travail) et `graph-prune` (dimanche, 04:23 UTC). Aucun secret.

Vérifier après le déploiement :
`select jobname, schedule, active from cron.job where jobname like 'graph-%' order by jobname;` doit lister six jobs,
dont `graph-rebuild` (`* * * * *`) et `graph-prune` (`23 4 * * 0`).

**Recalculer le graphe** quand l'algorithme ou ses paramètres d'apprentissage changent :

1. Créer la nouvelle version, sans l'activer, après revue des vecteurs `shared/test-vectors/learn/` :
   ```sql
   insert into graph.algo_versions (version, server_params, device_params, note)
   select 3, server_params || '{"SKIP2_FACTOR": 0.4}', device_params, 'Pourquoi ce changement'
   from graph.active_version();
   ```
2. Lancer le recalcul : `select graph.start_rebuild(3);` (nombre de magasins mis en file). La version active continue
   de servir l'apprentissage pendant ce temps.
3. Suivre : `select status, count(*), max(attempts) from graph.rebuild_jobs group by status;`. Le job traite un
   magasin par minute. Le dernier travail active la version 3 (`select * from graph.active_version();`) et relance
   les magasins appris entre-temps avec l'ancienne version : ils repassent en `pending` puis en `done`.
4. Un travail `failed` (3 échecs, message dans `error`) bloque la bascule. Après correction :
   `update graph.rebuild_jobs set status = 'pending', attempts = 0 where status = 'failed';`.
5. Abandonner un recalcul :
   `delete from graph.rebuild_jobs where status <> 'done'; select graph.start_rebuild(<version active>);`. Les
   magasins déjà recalculés reviennent ainsi aux paramètres de la version active.

Le recalcul repart des visites présentes : les contributions des comptes supprimés quittent le graphe. Pendant le
rejeu d'un magasin, ses visites sont verrouillées. Une suppression de compte qui les touche échoue alors en `55P03`
au bout de 5 s, et l'app réessaie.

**Purge.** Chaque semaine, les arêtes et entrées dont le poids décru est sous 0,01 disparaissent. Le journal :
`select finished_at, claimed, skipped, detail from graph.runs where kind = 'prune' order by id desc limit 4;`
(`skipped` : magasins verrouillés, purgés la semaine suivante).
