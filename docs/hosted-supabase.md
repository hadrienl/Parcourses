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
5. Vérifier :
   - `scripts/hosted-auth-config.py` doit répondre « à jour ». La relecture porte sur la configuration enregistrée,
     et l'Auth redémarre ensuite en quelques instants.
   - Lier une adresse à un compte anonyme depuis l'app (« Se connecter ») : l'e-mail doit porter un code à 6 chiffres.
     Une connexion directe avec une adresse inconnue est refusée par le hook `before_user_created` : c'est voulu.
