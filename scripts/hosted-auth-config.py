#!/usr/bin/env python3
"""Réglages Auth du projet Supabase hébergé, tirés de supabase/config.toml (#87).

`supabase/config.toml` ne s'applique qu'à la pile locale : sur l'hébergé, ces réglages se posent par l'API de gestion
(PATCH /v1/projects/{ref}/config/auth). Sans eux, l'hébergé envoie un lien magique (modèle par défaut) au lieu du code
à 6 chiffres que les apps attendent, et le hook before_user_created ne bloque pas les créations de comptes e-mail.

Seuls les réglages de la table PUSHED sont comparés ou poussés. Ne sont **jamais** envoyés : site_url et les URL de
redirection (celles du dépôt visent 127.0.0.1), le SMTP (local : désactivé ; hébergé : Resend, réglé à part avec ses
secrets), les limites de débit et max_frequency (valeurs de test locales, plus permissives que l'hébergé).

Usage (depuis la racine du dépôt) :
  SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… scripts/hosted-auth-config.py           # --check : compare, n'écrit rien
  SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… scripts/hosted-auth-config.py --apply   # pousse les écarts, puis relit
  scripts/hosted-auth-config.py --plan                                                   # réglages voulus, sans réseau

Le jeton (https://supabase.com/dashboard/account/tokens) n'est jamais affiché. Codes de sortie : 0 à jour (ou appliqué
et relu conforme), 1 écarts trouvés en --check ou relecture non conforme, 2 erreur d'usage ou d'API (après un
--apply, relancer : le PATCH a pu passer avant une erreur de relecture). Python 3.11 ou plus.
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

# Modèles d'e-mail poussés : (section de config.toml, suffixe des champs de l'API).
TEMPLATES = ("magic_link", "confirmation", "email_change", "recovery")


def _get(config: dict[str, Any], dotted: str) -> Any:
    node: Any = config
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(f"{dotted} absent de supabase/config.toml")
        node = node[part]
    return node


# Champ de l'API → valeur tirée de config.toml. Liste blanche : rien d'autre n'est lu ni envoyé.
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

# Jamais envoyés, même si un jour ils entraient dans PUSHED par erreur : le test le vérifie.
FORBIDDEN_PREFIXES = ("site_url", "uri_allow_list", "smtp_", "rate_limit_", "external_email_redirect")


def _template(config: dict[str, Any], name: str) -> str:
    path = _get(config, f"auth.email.template.{name}.content_path")
    file = (ROOT / path).resolve()
    if ROOT not in file.parents:
        raise ValueError(f"modèle hors du dépôt : {path}")
    return file.read_text(encoding="utf-8")


def desired(config: dict[str, Any]) -> dict[str, Any]:
    """Réglages voulus sur l'hébergé, d'après config.toml et supabase/templates/."""
    values = {field: read(config) for field, read in PUSHED.items()}
    for name in TEMPLATES:
        values[f"mailer_subjects_{name}"] = _get(config, f"auth.email.template.{name}.subject")
        values[f"mailer_templates_{name}_content"] = _template(config, name)
    for field in values:
        if field.startswith(FORBIDDEN_PREFIXES):
            raise ValueError(f"réglage interdit dans la liste poussée : {field}")
    return values


def _same(field: str, want: Any, have: Any) -> bool:
    # Modèles : l'hébergé peut retirer le saut de ligne final.
    if field.endswith("_content") and isinstance(want, str) and isinstance(have, str):
        return want.rstrip("\n") == have.rstrip("\n")
    return want == have


def differences(want: dict[str, Any], have: dict[str, Any]) -> dict[str, tuple[Any, Any]]:
    return {f: (v, have.get(f)) for f, v in want.items() if not _same(f, v, have.get(f))}


def _describe(field: str, value: Any) -> str:
    # Les modèles sont longs : on n'affiche que leur taille.
    if field.endswith("_content"):
        return "absent" if value is None else f"{len(value)} caractères"
    return json.dumps(value, ensure_ascii=False)


def _request(method: str, ref: str, token: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
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
        detail = err.read().decode("utf-8", "replace")[:300]
        print(f"API de gestion : {method} {err.code} {detail}", file=sys.stderr)
        raise SystemExit(2) from None
    except urllib.error.URLError as err:
        print(f"API de gestion injoignable : {err.reason}", file=sys.stderr)
        raise SystemExit(2) from None
    except (http.client.HTTPException, json.JSONDecodeError, UnicodeDecodeError, TimeoutError) as err:
        print(f"API de gestion : {method}, réponse illisible ({type(err).__name__})", file=sys.stderr)
        raise SystemExit(2) from None
    if not isinstance(payload, dict):
        print(f"API de gestion : {method}, réponse inattendue (pas un objet JSON)", file=sys.stderr)
        raise SystemExit(2)
    return payload


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="compare l'hébergé au dépôt (par défaut)")
    mode.add_argument("--apply", action="store_true", help="pousse les écarts, puis relit")
    mode.add_argument("--plan", action="store_true", help="affiche les réglages voulus, sans réseau")
    args = parser.parse_args(argv)

    with CONFIG.open("rb") as fh:
        want = desired(tomllib.load(fh))

    if args.plan:
        for field, value in want.items():
            print(f"{field} = {_describe(field, value)}")
        return 0

    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
    ref = os.environ.get("SUPABASE_PROJECT_REF", "")
    if not token or not ref:
        print("SUPABASE_ACCESS_TOKEN et SUPABASE_PROJECT_REF sont requis.", file=sys.stderr)
        return 2

    diff = differences(want, _request("GET", ref, token))
    if not diff:
        print(f"Auth hébergée à jour ({len(want)} réglages comparés).")
        return 0
    for field, (wanted, had) in diff.items():
        print(f"{field} : hébergé {_describe(field, had)} → dépôt {_describe(field, wanted)}")
    if not args.apply:
        print(f"{len(diff)} écart(s). Relancer avec --apply pour les pousser.")
        return 1

    _request("PATCH", ref, token, {field: want[field] for field in diff})
    left = differences(want, _request("GET", ref, token))
    if left:
        print(f"Après --apply, {len(left)} écart(s) restent : {', '.join(left)}", file=sys.stderr)
        return 1
    print(f"{len(diff)} réglage(s) poussé(s), relus conformes.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (KeyError, ValueError, OSError) as err:
        print(f"Erreur : {err}", file=sys.stderr)
        sys.exit(2)
