#!/usr/bin/env python3
"""Tests de scripts/hosted-auth-config.py, sans réseau (#87).

  python3 scripts/test_hosted_auth_config.py
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import os
import tomllib
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("hosted_auth_config", HERE / "hosted-auth-config.py")
assert _spec and _spec.loader
hac = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hac)

with hac.CONFIG.open("rb") as _fh:
    CONFIG = tomllib.load(_fh)


class FakeApi:
    """Remplace l'API de gestion : GET rend l'état, PATCH le modifie et garde le corps envoyé."""

    def __init__(self, state: dict):
        self.state = dict(state)
        self.patches: list[dict] = []

    def __call__(self, method, ref, token, body=None):
        assert token == "jeton" and ref == "ref"
        if method == "PATCH":
            self.patches.append(dict(body))
            self.state.update(body)
        return dict(self.state)


def run(args: list[str], api: FakeApi) -> tuple[int, str]:
    out = io.StringIO()
    env = {"SUPABASE_ACCESS_TOKEN": "jeton", "SUPABASE_PROJECT_REF": "ref"}
    with mock.patch.object(hac, "_request", api), mock.patch.dict(os.environ, env), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = hac.main(args)
    return code, out.getvalue()


class DesiredTest(unittest.TestCase):
    def test_code_a_six_chiffres_valable_quinze_minutes(self):
        want = hac.desired(CONFIG)
        self.assertEqual(want["mailer_otp_length"], 6)
        self.assertEqual(want["mailer_otp_exp"], 900)

    def test_modeles_avec_le_code_et_sans_lien(self):
        want = hac.desired(CONFIG)
        for name in hac.TEMPLATES:
            content = want[f"mailer_templates_{name}_content"]
            self.assertIn("{{ .Token }}", content, name)
            self.assertNotIn("ConfirmationURL", content, name)
            self.assertNotIn("{{ .Token }}", want[f"mailer_subjects_{name}"], f"code dans l'objet : {name}")

    def test_inscriptions_et_confirmations_dans_le_bon_sens(self):
        want = hac.desired(CONFIG)
        self.assertIs(want["disable_signup"], False)
        self.assertIs(want["mailer_autoconfirm"], False)
        self.assertIs(want["external_email_enabled"], True)
        self.assertIs(want["external_anonymous_users_enabled"], True)
        self.assertIs(want["mailer_secure_email_change_enabled"], True)

    def test_hook_before_user_created(self):
        want = hac.desired(CONFIG)
        self.assertIs(want["hook_before_user_created_enabled"], True)
        self.assertEqual(want["hook_before_user_created_uri"], "pg-functions://postgres/accounts/before_user_created")

    def test_jamais_site_url_ni_smtp_ni_limites(self):
        for field in hac.desired(CONFIG):
            self.assertFalse(field.startswith(hac.FORBIDDEN_PREFIXES), field)

    def test_un_reglage_interdit_ajoute_par_erreur_est_refuse(self):
        with mock.patch.dict(hac.PUSHED, {"site_url": lambda c: c["auth"]["site_url"]}):
            with self.assertRaises(ValueError):
                hac.desired(CONFIG)

    def test_modele_hors_du_depot_refuse(self):
        config = copy.deepcopy(CONFIG)
        config["auth"]["email"]["template"]["recovery"]["content_path"] = "../../etc/hosts"
        with self.assertRaises(ValueError):
            hac.desired(config)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class RequestTest(unittest.TestCase):
    """`_request` avec urlopen simulé : URL, en-têtes, erreurs, et jamais le jeton à l'écran."""

    def call(self, effect):
        seen = []

        def urlopen(req, timeout):
            seen.append(req)
            if isinstance(effect, BaseException):
                raise effect
            return FakeResponse(effect)

        err = io.StringIO()
        with mock.patch.object(hac.urllib.request, "urlopen", urlopen), contextlib.redirect_stderr(err):
            try:
                result = hac._request("GET", "ref", "jeton-secret")
                code = 0
            except SystemExit as exit_:
                result, code = None, exit_.code
        return result, code, err.getvalue(), seen

    def test_succes(self):
        result, code, _, seen = self.call(b'{"mailer_otp_length": 6}')
        self.assertEqual((result, code), ({"mailer_otp_length": 6}, 0))
        self.assertEqual(seen[0].full_url, "https://api.supabase.com/v1/projects/ref/config/auth")
        self.assertEqual(seen[0].get_header("Authorization"), "Bearer jeton-secret")

    def test_erreurs_http_sortie_2_sans_le_jeton(self):
        for status in (401, 429, 500):
            error = hac.urllib.error.HTTPError("u", status, "x", None, io.BytesIO(b'{"message":"refus"}'))
            _, code, err, _ = self.call(error)
            self.assertEqual(code, 2, status)
            self.assertIn(str(status), err)
            self.assertNotIn("jeton-secret", err)

    def test_reponse_illisible_ou_pas_un_objet(self):
        for body in (b"<html>", b"[1, 2]"):
            _, code, err, _ = self.call(body)
            self.assertEqual(code, 2, body)
            self.assertNotIn("jeton-secret", err)


class CheckApplyTest(unittest.TestCase):
    def test_check_signale_les_ecarts_sans_rien_ecrire(self):
        api = FakeApi({"mailer_otp_length": 8, "site_url": "https://exemple.test"})
        code, out = run(["--check"], api)
        self.assertEqual(code, 1)
        self.assertEqual(api.patches, [])
        self.assertIn("mailer_otp_length : hébergé 8 → dépôt 6", out)
        self.assertNotIn("jeton", out)

    def test_mode_par_defaut_est_check(self):
        api = FakeApi({})
        code, _ = run([], api)
        self.assertEqual(code, 1)
        self.assertEqual(api.patches, [])

    def test_apply_ne_pousse_que_les_ecarts_puis_relit(self):
        want = hac.desired(CONFIG)
        state = dict(want, mailer_otp_length=8, site_url="https://exemple.test", smtp_host="smtp.resend.com")
        api = FakeApi(state)
        code, out = run(["--apply"], api)
        self.assertEqual(code, 0, out)
        self.assertEqual(api.patches, [{"mailer_otp_length": 6}])
        self.assertEqual(api.state["site_url"], "https://exemple.test")
        self.assertEqual(api.state["smtp_host"], "smtp.resend.com")

    def test_apply_idempotent(self):
        api = FakeApi(hac.desired(CONFIG))
        code, out = run(["--apply"], api)
        self.assertEqual(code, 0)
        self.assertEqual(api.patches, [])
        self.assertIn("à jour", out)

    def test_saut_de_ligne_final_retire_par_l_heberge(self):
        want = hac.desired(CONFIG)
        state = {f: (v.rstrip("\n") if f.endswith("_content") else v) for f, v in want.items()}
        code, _ = run(["--check"], FakeApi(state))
        self.assertEqual(code, 0)

    def test_relecture_non_conforme(self):
        class Stubborn(FakeApi):
            def __call__(self, method, ref, token, body=None):
                if method == "PATCH":
                    self.patches.append(dict(body))
                    return dict(self.state)
                return dict(self.state)

        code, _ = run(["--apply"], Stubborn({}))
        self.assertEqual(code, 1)

    def test_sans_jeton(self):
        with mock.patch.dict(os.environ, {"SUPABASE_ACCESS_TOKEN": "", "SUPABASE_PROJECT_REF": ""}), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(hac.main(["--check"]), 2)

    def test_plan_sans_reseau(self):
        def no_network(*_):
            raise AssertionError("appel réseau")

        code, out = run(["--plan"], no_network)  # type: ignore[arg-type]
        self.assertEqual(code, 0)
        self.assertIn("mailer_otp_length = 6", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
