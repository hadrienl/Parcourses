#!/usr/bin/env python3
"""Réglages Auth du projet Supabase hébergé, tirés de supabase/config.toml (#87).

`supabase/config.toml` ne s'applique qu'à la pile locale. Sur l'hébergé, ces réglages se posent par l'API de gestion
(PATCH /v1/projects/{ref}/config/auth). Sans eux, l'hébergé envoie un lien magique (modèle par défaut) au lieu du code
à 6 chiffres attendu par les apps, et le hook before_user_created ne bloque pas les créations de comptes e-mail.

Trois groupes, poussés dans cet ordre, chacun par son propre PATCH :
  1. auth : code (longueur, durée), hook before_user_created, inscription, anonymes, confirmations (table PUSHED) ;
  2. smtp : seulement si les variables SMTP_* sont définies (voir SMTP_ENV). Elles ne sont jamais affichées, et le mot
     de passe n'est jamais relu ni comparé ;
  3. templates : objets et modèles des e-mails. L'hébergé les refuse sans SMTP personnalisé (400
     entitlement_required, feature auth.email_templates) : ils attendent alors, avec un message clair.

Ne sont **jamais** envoyés : site_url et les URL de redirection (celles du dépôt visent 127.0.0.1), les limites de
débit et max_frequency (valeurs de test locales, plus permissives que l'hébergé), et le SMTP de config.toml (le SMTP
ne vient que de l'environnement).

Usage, depuis la racine du dépôt :
  export SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=…
  scripts/hosted-auth-config.py            # --check : compare, n'écrit rien
  scripts/hosted-auth-config.py --apply    # pousse les écarts groupe par groupe, puis relit
  scripts/hosted-auth-config.py --plan     # réglages voulus, sans réseau
  SMTP_HOST=smtp-relay.brevo.com SMTP_PORT=587 SMTP_USER=… SMTP_PASS=… SMTP_ADMIN_EMAIL=… \\
    scripts/hosted-auth-config.py --apply  # avec le SMTP (Brevo ici ; Resend : smtp.resend.com, 465, resend)
  --rotate-smtp-pass : renvoie le mot de passe SMTP même si le reste du SMTP est à jour.

Le jeton (https://supabase.com/dashboard/account/tokens) n'est jamais affiché. Codes de sortie :
  0 : à jour, ou appliqué et relu conforme ;
  1 : écarts trouvés (--check), ou relecture non conforme ;
  2 : erreur d'usage ou d'API (après un --apply, relancer : un PATCH a pu passer avant l'erreur) ;
  3 : --apply partiel, modèles en attente d'un SMTP personnalisé.
Python 3.11 ou plus.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys

if sys.version_info < (3, 11):  # tomllib
    print("Python 3.11 ou plus est requis (tomllib).", file=sys.stderr)
    sys.exit(2)

import tomllib  # noqa: E402
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "supabase" / "config.toml"
API = "https://api.supabase.com/v1/projects/{ref}/config/auth"

# Modèles d'e-mail poussés : section de config.toml = suffixe des champs de l'API.
TEMPLATES = ("magic_link", "confirmation", "email_change", "recovery")

EXIT_OK, EXIT_DIFF, EXIT_ERROR, EXIT_TEMPLATES_PENDING = 0, 1, 2, 3


def _get(config: dict[str, Any], dotted: str) -> Any:
    node: Any = config
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(f"{dotted} absent de supabase/config.toml")
        node = node[part]
    return node


# Groupe auth : champ de l'API → valeur tirée de config.toml. Liste blanche : rien d'autre n'est lu ni envoyé.
PUSHED: dict[str, Callable[[dict[str, Any]], Any]] = {
    "mailer_otp_length": lambda c: _get(c, "auth.email.otp_length"),
    "mailer_otp_exp": lambda c: _get(c, "auth.email.otp_expiry"),
    "external_email_enabled": lambda c: _get(c, "auth.email.enable_signup"),
    "disable_signup": lambda c: not _get(c, "auth.enable_signup"),
    "external_anonymous_users_enabled": lambda c: _get(c, "auth.enable_anonymous_sign_ins"),
    "mailer_autoconfirm": lambda c: not _get(c, "auth.email.enable_confirmations"),
    "mailer_secure_email_change_enabled": lambda c: _get(c, "auth.email.double_confirm_changes"),
    "hook_before_user_created_enabled": lambda c: _get(c, "auth.hook.before_user_created.enabled"),
    "hook_before_user_created_uri": lambda c: _get(c, "auth.hook.before_user_created.uri"),
}

# Jamais tirés de config.toml, même ajoutés par erreur à PUSHED : le test le vérifie.
FORBIDDEN_PREFIXES = ("site_url", "uri_allow_list", "smtp_", "rate_limit_", "external_email_redirect")

# Groupe smtp : variable d'environnement → champ de l'API. SMTP_SENDER_NAME est facultatif (défaut : le
# sender_name de config.toml). Le port est une chaîne pour l'API.
SMTP_ENV = {
    "SMTP_HOST": "smtp_host",
    "SMTP_PORT": "smtp_port",
    "SMTP_USER": "smtp_user",
    "SMTP_PASS": "smtp_pass",
    "SMTP_ADMIN_EMAIL": "smtp_admin_email",
    "SMTP_SENDER_NAME": "smtp_sender_name",
}
SMTP_OPTIONAL = {"SMTP_SENDER_NAME"}
SMTP_SECRET = "smtp_pass"


def _template(config: dict[str, Any], name: str) -> str:
    path = _get(config, f"auth.email.template.{name}.content_path")
    file = (ROOT / path).resolve()
    if ROOT not in file.parents:
        raise ValueError(f"modèle hors du dépôt : {path}")
    return file.read_text(encoding="utf-8")


def _guard(values: dict[str, Any]) -> dict[str, Any]:
    for field in values:
        if field.startswith(FORBIDDEN_PREFIXES):
            raise ValueError(f"réglage interdit dans la liste poussée : {field}")
    return values


def desired_auth(config: dict[str, Any]) -> dict[str, Any]:
    """Groupe auth : code, hook, inscription et confirmations, d'après config.toml."""
    return _guard({field: read(config) for field, read in PUSHED.items()})


def desired_templates(config: dict[str, Any]) -> dict[str, Any]:
    """Groupe templates : objets et modèles, d'après config.toml et supabase/templates/."""
    values: dict[str, Any] = {}
    for name in TEMPLATES:
        values[f"mailer_subjects_{name}"] = _get(config, f"auth.email.template.{name}.subject")
        values[f"mailer_templates_{name}_content"] = _template(config, name)
    return _guard(values)


def desired(config: dict[str, Any]) -> dict[str, Any]:
    """Tout ce qui vient de config.toml (auth et templates)."""
    return {**desired_auth(config), **desired_templates(config)}


def smtp_from_env(config: dict[str, Any], env: dict[str, str]) -> dict[str, str] | None:
    """Groupe smtp, lu dans l'environnement. None si aucune variable SMTP_* n'est définie."""
    given = {name: env[name] for name in SMTP_ENV if env.get(name)}
    if not given:
        return None
    missing = [name for name in SMTP_ENV if name not in given and name not in SMTP_OPTIONAL]
    if missing:
        raise ValueError(f"SMTP incomplet, variables manquantes : {', '.join(missing)}")
    if not given["SMTP_PORT"].isdigit():
        raise ValueError("SMTP_PORT doit être un numéro de port")
    given.setdefault("SMTP_SENDER_NAME", str(_get(config, "auth.email.smtp.sender_name")))
    return {SMTP_ENV[name]: value for name, value in given.items()}


def _same(field: str, want: Any, have: Any) -> bool:
    # Modèles : l'hébergé peut retirer le saut de ligne final.
    if field.endswith("_content") and isinstance(want, str) and isinstance(have, str):
        return want.rstrip("\n") == have.rstrip("\n")
    return want == have


def differences(want: dict[str, Any], have: dict[str, Any]) -> dict[str, tuple[Any, Any]]:
    return {f: (v, have.get(f)) for f, v in want.items() if not _same(f, v, have.get(f))}


def smtp_differences(want: dict[str, str], have: dict[str, Any]) -> list[str]:
    """Champs SMTP différents, sans le mot de passe (jamais relu). Les valeurs ne sortent pas d'ici."""
    return [f for f, v in want.items() if f != SMTP_SECRET and str(have.get(f) or "") != v]


def has_smtp(have: dict[str, Any]) -> bool:
    return bool(have.get("smtp_host")) and bool(have.get("smtp_admin_email"))


def _describe(field: str, value: Any) -> str:
    # Les modèles sont longs : on n'affiche que leur taille.
    if field.endswith("_content"):
        return "absent" if value is None else f"{len(value)} caractères"
    return json.dumps(value, ensure_ascii=False)


class ApiError(Exception):
    def __init__(self, status: int, body: str):
        super().__init__(f"{status}")
        self.status = status
        self.body = body


def _scrub(text: str, secrets: list[str]) -> str:
    for secret in secrets:
        if secret:
            text = text.replace(secret, "•••")
    return text


def _request(
    method: str, ref: str, token: str, body: dict[str, Any] | None = None, secrets: list[str] | None = None
) -> dict[str, Any]:
    """Appel de l'API de gestion. Erreur HTTP : ApiError, corps tronqué et nettoyé du jeton et des secrets SMTP."""
    hidden = [token, *(secrets or [])]
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(API.format(ref=ref), data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "parcourses-hosted-auth-config")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as err:
        raise ApiError(err.code, _scrub(err.read().decode("utf-8", "replace")[:300], hidden)) from None
    except urllib.error.URLError as err:
        print(f"API de gestion injoignable : {err.reason}", file=sys.stderr)
        raise SystemExit(EXIT_ERROR) from None
    except (http.client.HTTPException, json.JSONDecodeError, UnicodeDecodeError, TimeoutError) as err:
        print(f"API de gestion : {method}, réponse illisible ({type(err).__name__})", file=sys.stderr)
        raise SystemExit(EXIT_ERROR) from None
    if not isinstance(payload, dict):
        print(f"API de gestion : {method}, réponse inattendue (pas un objet JSON)", file=sys.stderr)
        raise SystemExit(EXIT_ERROR)
    return payload


def _call(method: str, ref: str, token: str, body: dict[str, Any] | None = None, secrets: list[str] | None = None):
    try:
        return _request(method, ref, token, body, secrets)
    except ApiError as err:
        print(f"API de gestion : {method} {err.status} {err.body}", file=sys.stderr)
        raise SystemExit(EXIT_ERROR) from None


def _is_template_entitlement(err: ApiError) -> bool:
    return err.status == 400 and ("entitlement_required" in err.body or "auth.email_templates" in err.body)


NO_SMTP = (
    "Modèles d'e-mail en attente : l'hébergé les refuse sans SMTP personnalisé (entitlement_required). Tant qu'ils "
    "attendent, les e-mails portent le lien par défaut et pas le code : la connexion par code des apps ne marche pas. "
    "Définir SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS et SMTP_ADMIN_EMAIL (docs/hosted-supabase.md), puis relancer "
    "--apply."
)


def main(argv: list[str], env: dict[str, str] | None = None) -> int:
    env = dict(os.environ) if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="compare l'hébergé au dépôt (par défaut)")
    mode.add_argument("--apply", action="store_true", help="pousse les écarts groupe par groupe, puis relit")
    mode.add_argument("--plan", action="store_true", help="affiche les réglages voulus, sans réseau")
    parser.add_argument("--rotate-smtp-pass", action="store_true", help="renvoie le mot de passe SMTP")
    args = parser.parse_args(argv)

    with CONFIG.open("rb") as fh:
        config = tomllib.load(fh)
    want_auth, want_templates = desired_auth(config), desired_templates(config)
    smtp = smtp_from_env(config, env)

    if args.plan:
        for field, value in {**want_auth, **want_templates}.items():
            print(f"{field} = {_describe(field, value)}")
        print("smtp : " + ("depuis SMTP_* (valeurs non affichées)" if smtp else "non fourni (variables SMTP_* absentes)"))
        return EXIT_OK

    token, ref = env.get("SUPABASE_ACCESS_TOKEN", ""), env.get("SUPABASE_PROJECT_REF", "")
    if not token or not ref:
        print("SUPABASE_ACCESS_TOKEN et SUPABASE_PROJECT_REF sont requis.", file=sys.stderr)
        return EXIT_ERROR
    secrets = list(smtp.values()) if smtp else []

    have = _call("GET", ref, token, secrets=secrets)
    auth_diff = differences(want_auth, have)
    template_diff = differences(want_templates, have)
    smtp_diff = smtp_differences(smtp, have) if smtp else []
    push_smtp = bool(smtp) and (bool(smtp_diff) or not has_smtp(have) or args.rotate_smtp_pass)

    for field, (wanted, had) in {**auth_diff, **template_diff}.items():
        print(f"{field} : hébergé {_describe(field, had)} → dépôt {_describe(field, wanted)}")
    if smtp_diff:
        print(f"smtp : à mettre à jour ({', '.join(smtp_diff)}, valeurs non affichées)")
    elif smtp and not has_smtp(have):
        print("smtp : absent de l'hébergé, à configurer depuis SMTP_*")
    if template_diff and not has_smtp(have) and not smtp:
        print("modèles : l'hébergé n'a pas de SMTP personnalisé, ils ne pourront pas être poussés sans SMTP_*.")

    if not auth_diff and not template_diff and not push_smtp:
        print(f"Auth hébergée à jour ({len(want_auth) + len(want_templates)} réglages comparés"
              + (", SMTP compris)." if smtp else ")."))
        return EXIT_OK
    if not args.apply:
        print("Écarts trouvés. Relancer avec --apply pour les pousser.")
        return EXIT_DIFF

    # 1. auth : indépendant des modèles et du SMTP.
    if auth_diff:
        _call("PATCH", ref, token, {f: want_auth[f] for f in auth_diff})
        print(f"auth : {len(auth_diff)} réglage(s) poussé(s).")
    # 2. smtp, mot de passe compris ; aucune valeur affichée.
    if push_smtp:
        assert smtp is not None
        _call("PATCH", ref, token, dict(smtp), secrets=secrets)
        print("smtp : configuré depuis SMTP_*.")
    # 3. templates, seulement avec un SMTP personnalisé.
    pending = False
    if template_diff:
        if has_smtp(have) or push_smtp:
            try:
                _request("PATCH", ref, token, {f: want_templates[f] for f in template_diff}, secrets)
                print(f"templates : {len(template_diff)} réglage(s) poussé(s).")
            except ApiError as err:
                if not _is_template_entitlement(err):
                    print(f"API de gestion : PATCH {err.status} {err.body}", file=sys.stderr)
                    return EXIT_ERROR
                print(NO_SMTP, file=sys.stderr)
                pending = True
        else:
            print(NO_SMTP, file=sys.stderr)
            pending = True

    after = _call("GET", ref, token, secrets=secrets)
    left = list(differences(want_auth, after))
    if not pending:
        left += list(differences(want_templates, after))
    if smtp:
        left += smtp_differences(smtp, after)
    if left:
        print(f"Après --apply, {len(left)} écart(s) restent : {', '.join(left)}", file=sys.stderr)
        return EXIT_DIFF
    if pending:
        print("Auth et SMTP relus conformes ; modèles en attente d'un SMTP personnalisé.")
        return EXIT_TEMPLATES_PENDING
    print("Relu conforme.")
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (KeyError, ValueError, OSError) as err:
        print(f"Erreur : {err}", file=sys.stderr)
        sys.exit(EXIT_ERROR)
