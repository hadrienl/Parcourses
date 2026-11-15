# Projet Supabase hébergé : ce que `config.toml` n'applique pas

`supabase/config.toml` ne règle que la pile **locale** (`supabase start`). Sur le projet hébergé, les migrations passent
par `supabase db push`, mais **l'Auth, les modèles d'e-mail et les hooks ne suivent pas** : ils se règlent par l'API de
gestion ou par le tableau de bord. Si on l'oublie, l'hébergé garde ses valeurs par défaut. C'est ce qui s'est passé
pour #87 : un lien magique vers `localhost` au lieu du code, un code à 8 chiffres au lieu de 6, et aucun hook
`before_user_created`.

## Après une modification de l'Auth, lancer `scripts/hosted-auth-config.py`

Cela concerne toute modification de `[auth…]` dans `supabase/config.toml`, et de `supabase/templates/`.

```sh
export SUPABASE_ACCESS_TOKEN=…   # https://supabase.com/dashboard/account/tokens, jamais commité
export SUPABASE_PROJECT_REF=…

scripts/hosted-auth-config.py            # --check : compare l'hébergé au dépôt, n'écrit rien (sortie 1 si écart)
scripts/hosted-auth-config.py --apply    # pousse les seuls écarts, puis relit (sortie 0 si conforme)
scripts/hosted-auth-config.py --plan     # réglages voulus, sans réseau
```

Le script est idempotent : un second `--apply` ne pousse rien. Il ne lit dans `config.toml` qu'une liste blanche de
réglages (table `PUSHED` du script), plus les objets et modèles `magic_link`, `confirmation`, `email_change` et
`recovery` :

| Hébergé (API de gestion) | Dépôt (`config.toml`) |
| --- | --- |
| `mailer_otp_length`, `mailer_otp_exp` | `auth.email.otp_length`, `auth.email.otp_expiry` |
| `mailer_subjects_*`, `mailer_templates_*_content` | `auth.email.template.*` (`subject`, `content_path`) |
| `hook_before_user_created_enabled`, `hook_before_user_created_uri` | `auth.hook.before_user_created` |
| `external_email_enabled`, `disable_signup`, `external_anonymous_users_enabled` | `auth.email.enable_signup`, `auth.enable_signup`, `auth.enable_anonymous_sign_ins` |
| `mailer_autoconfirm`, `mailer_secure_email_change_enabled` | `auth.email.enable_confirmations` (inversé), `auth.email.double_confirm_changes` |

**Jamais poussés** :
- `site_url` et les URL de redirection : celles du dépôt visent `127.0.0.1` ;
- le SMTP : désactivé en local, Resend sur l'hébergé, réglé à part avec ses secrets ;
- les limites de débit et `max_frequency` : valeurs de test locales, plus permissives.

Les tests du script tournent en CI (`supabase`), sans réseau : `python3 scripts/test_hosted_auth_config.py`.

## Ordre de mise en production

1. `supabase db push` : migrations, dont la fonction du hook (`accounts.before_user_created`), qui doit exister avant
   que le hook soit activé.
2. `scripts/hosted-auth-config.py --apply`.
3. Edge Functions : `supabase functions deploy send-invitation`, avec ses secrets (`RESEND_API_KEY`,
   `INVITATION_FROM`, plus tard `INVITATION_BASE_URL`).
4. Vérifier : `scripts/hosted-auth-config.py` doit répondre « à jour », et une connexion de test doit recevoir un code à
   6 chiffres sans lien.
