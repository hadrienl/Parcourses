#!/usr/bin/env python3
"""Tests de scripts/hosted-auth-config.py, sans réseau (#87).

  python3 scripts/test_hosted_auth_config.py
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
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

BASE_ENV = {"SUPABASE_ACCESS_TOKEN": "jeton", "SUPABASE_PROJECT_REF": "ref"}
BREVO = {
    "SMTP_HOST": "smtp-relay.brevo.com",
    "SMTP_PORT": "587",
    "SMTP_USER": "compte-brevo@exemple.test",
    "SMTP_PASS": "mot-de-passe-smtp",
    "SMTP_ADMIN_EMAIL": "noreply@exemple.test",
}
SMTP_STATE = {
    "smtp_host": "smtp-relay.brevo.com",
    "smtp_port": "587",
    "smtp_user": "compte-brevo@exemple.test",
    "smtp_admin_email": "noreply@exemple.test",
    "smtp_sender_name": "Parcourses",
    "smtp_pass": "******",
}
ENTITLEMENT = '{"message":"entitlement_required: feature auth.email_templates, configure a custom SMTP provider"}'


class FakeApi:
    """API de gestion simulée : GET rend l'état, PATCH le modifie et garde le corps envoyé.

    Comme l'hébergé gratuit : un PATCH de modèles sans SMTP personnalisé est refusé (400 entitlement_required).
    """

    def __init__(self, state: dict, enforce_entitlement: bool = True):
        self.state = dict(state)
        self.patches: list[dict] = []
        self.enforce_entitlement = enforce_entitlement

    def __call__(self, method, ref, token, body=None, secrets=None):
        assert token == "jeton" and ref == "ref"
        if method == "PATCH":
            self.patches.append(dict(body))
            templates = any(k.startswith(("mailer_templates_", "mailer_subjects_")) for k in body)
            if templates and self.enforce_entitlement and not hac.has_smtp(self.state):
                raise hac.ApiError(400, ENTITLEMENT)
            self.state.update(body)
        return dict(self.state)


def run(args: list[str], api, env: dict | None = None) -> tuple[int, str]:
    out = io.StringIO()
    with mock.patch.object(hac, "_request", api), contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = hac.main(args, {**BASE_ENV, **(env or {})})
    return code, out.getvalue()


def secret_free(test: unittest.TestCase, out: str) -> None:
    for value in ("jeton", *BREVO.values()):
        test.assertNotIn(value, out)


class DesiredTest(unittest.TestCase):
    def test_code_a_six_chiffres_valable_quinze_minutes(self):
        want = hac.desired_auth(CONFIG)
        self.assertEqual(want["mailer_otp_length"], 6)
        self.assertEqual(want["mailer_otp_exp"], 900)

    def test_inscriptions_et_confirmations_dans_le_bon_sens(self):
        want = hac.desired_auth(CONFIG)
        self.assertIs(want["disable_signup"], False)
        self.assertIs(want["mailer_autoconfirm"], False)
        self.assertIs(want["external_email_enabled"], True)
        self.assertIs(want["external_anonymous_users_enabled"], True)
        self.assertIs(want["mailer_secure_email_change_enabled"], True)

    def test_modeles_avec_le_code_et_sans_lien(self):
        want = hac.desired_templates(CONFIG)
        for name in hac.TEMPLATES:
            content = want[f"mailer_templates_{name}_content"]
            self.assertIn("{{ .Token }}", content, name)
            self.assertNotIn("ConfirmationURL", content, name)
            self.assertNotIn("{{ .Token }}", want[f"mailer_subjects_{name}"], f"code dans l'objet : {name}")

    def test_groupes_separes(self):
        auth, templates = hac.desired_auth(CONFIG), hac.desired_templates(CONFIG)
        self.assertFalse(set(auth) & set(templates))
        self.assertFalse(any(f.startswith(("mailer_templates_", "mailer_subjects_")) for f in auth))

    def test_hook_before_user_created(self):
        want = hac.desired_auth(CONFIG)
        self.assertIs(want["hook_before_user_created_enabled"], True)
        self.assertEqual(want["hook_before_user_created_uri"], "pg-functions://postgres/accounts/before_user_created")

    def test_jamais_site_url_ni_smtp_ni_limites_depuis_config_toml(self):
        for field in hac.desired(CONFIG):
            self.assertFalse(field.startswith(hac.FORBIDDEN_PREFIXES), field)

    def test_un_reglage_interdit_ajoute_par_erreur_est_refuse(self):
        with mock.patch.dict(hac.PUSHED, {"site_url": lambda c: c["auth"]["site_url"]}):
            with self.assertRaises(ValueError):
                hac.desired_auth(CONFIG)

    def test_modele_hors_du_depot_refuse(self):
        config = copy.deepcopy(CONFIG)
        config["auth"]["email"]["template"]["recovery"]["content_path"] = "../../etc/hosts"
        with self.assertRaises(ValueError):
            hac.desired_templates(config)


class SmtpEnvTest(unittest.TestCase):
    def test_absent(self):
        self.assertIsNone(hac.smtp_from_env(CONFIG, {}))

    def test_brevo_avec_nom_par_defaut(self):
        smtp = hac.smtp_from_env(CONFIG, BREVO)
        self.assertEqual(smtp["smtp_host"], "smtp-relay.brevo.com")
        self.assertEqual(smtp["smtp_port"], "587")
        self.assertEqual(smtp["smtp_sender_name"], "Parcourses")

    def test_incomplet_nomme_les_variables_sans_leurs_valeurs(self):
        with self.assertRaises(ValueError) as ctx:
            hac.smtp_from_env(CONFIG, {"SMTP_HOST": "smtp-relay.brevo.com", "SMTP_PASS": "mot-de-passe-smtp"})
        message = str(ctx.exception)
        self.assertIn("SMTP_PORT", message)
        self.assertNotIn("mot-de-passe-smtp", message)

    def test_port_invalide(self):
        with self.assertRaises(ValueError):
            hac.smtp_from_env(CONFIG, {**BREVO, "SMTP_PORT": "587;x"})

    def test_mot_de_passe_jamais_compare(self):
        self.assertEqual(hac.smtp_differences(hac.smtp_from_env(CONFIG, BREVO), SMTP_STATE), [])


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class RequestTest(unittest.TestCase):
    """`_request` avec urlopen simulé : URL, en-têtes, erreurs, et jamais le jeton ni un secret à l'écran."""

    def call(self, effect, secrets=None):
        seen = []

        def urlopen(req, timeout):
            seen.append(req)
            if isinstance(effect, BaseException):
                raise effect
            return FakeResponse(effect)

        err = io.StringIO()
        with mock.patch.object(hac.urllib.request, "urlopen", urlopen), contextlib.redirect_stderr(err):
            try:
                result = hac._call("GET", "ref", "jeton-secret", secrets=secrets)
                code = 0
            except SystemExit as exit_:
                result, code = None, exit_.code
        return result, code, err.getvalue(), seen

    def test_succes(self):
        result, code, _, seen = self.call(b'{"mailer_otp_length": 6}')
        self.assertEqual((result, code), ({"mailer_otp_length": 6}, 0))
        self.assertEqual(seen[0].full_url, "https://api.supabase.com/v1/projects/ref/config/auth")
        self.assertEqual(seen[0].get_header("Authorization"), "Bearer jeton-secret")

    def test_erreurs_http_sortie_2_sans_le_jeton_ni_les_secrets(self):
        for status in (401, 429, 500):
            body = b'{"message":"refus jeton-secret mot-de-passe-smtp"}'
            error = hac.urllib.error.HTTPError("u", status, "x", None, io.BytesIO(body))
            _, code, err, _ = self.call(error, secrets=["mot-de-passe-smtp"])
            self.assertEqual(code, 2, status)
            self.assertIn(str(status), err)
            self.assertNotIn("jeton-secret", err)
            self.assertNotIn("mot-de-passe-smtp", err)

    def test_secret_a_cheval_sur_la_coupure_ou_echappe(self):
        body = ("x" * 295 + "mot-de-passe-smtp " + json.dumps({"v": 'mot"de"passe'})).encode()
        error = hac.urllib.error.HTTPError("u", 400, "x", None, io.BytesIO(body))
        _, _, err, _ = self.call(error, secrets=["mot-de-passe-smtp", 'mot"de"passe'])
        self.assertNotIn("mot-de-pas", err)
        self.assertNotIn('mot\\"de', err)

    def test_entete_invalide_sans_le_jeton(self):
        def urlopen(req, timeout):
            raise ValueError(f"Invalid header value {req.get_header('Authorization')!r}")

        err = io.StringIO()
        with mock.patch.object(hac.urllib.request, "urlopen", urlopen), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as ctx:
                hac._request("GET", "ref", "jeton-secret")
        self.assertEqual(ctx.exception.code, 2)
        self.assertNotIn("jeton-secret", err.getvalue())

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
        self.assertIn("ne pourront pas être poussés sans SMTP", out)
        secret_free(self, out)

    def test_mode_par_defaut_est_check(self):
        api = FakeApi({})
        code, _ = run([], api)
        self.assertEqual(code, 1)
        self.assertEqual(api.patches, [])

    def test_sans_smtp_auth_poussee_modeles_en_attente(self):
        # L'hébergé gratuit : hook déjà actif, code à 8 chiffres, aucun SMTP.
        auth = hac.desired_auth(CONFIG)
        api = FakeApi(dict(auth, mailer_otp_length=8, mailer_otp_exp=3600, site_url="https://exemple.test"))
        code, out = run(["--apply"], api)
        self.assertEqual(code, 3, out)
        self.assertEqual(api.patches, [{"mailer_otp_length": 6, "mailer_otp_exp": 900}])
        self.assertEqual(api.state["site_url"], "https://exemple.test")
        self.assertIn("SMTP personnalisé", out)

    def test_refus_entitlement_meme_avec_un_smtp_annonce(self):
        # L'hébergé dit avoir un SMTP mais refuse quand même les modèles : message clair, sortie 3.
        auth = hac.desired_auth(CONFIG)

        class Refusing(FakeApi):
            def __call__(self, method, ref, token, body=None, secrets=None):
                if method == "PATCH" and any(k.startswith("mailer_templates_") for k in body):
                    raise hac.ApiError(400, ENTITLEMENT)
                return super().__call__(method, ref, token, body, secrets)

        api = Refusing(dict(auth, **SMTP_STATE))
        code, out = run(["--apply"], api)
        self.assertEqual(code, 3, out)
        self.assertIn("SMTP personnalisé", out)
        self.assertIn("Auth relue conforme", out)
        self.assertNotIn("Auth et SMTP", out)

    def test_avec_smtp_brevo_trois_patch_dans_l_ordre(self):
        auth = hac.desired_auth(CONFIG)
        api = FakeApi(dict(auth, mailer_otp_length=8))
        code, out = run(["--apply"], api, BREVO)
        self.assertEqual(code, 0, out)
        self.assertEqual(len(api.patches), 3)
        self.assertEqual(api.patches[0], {"mailer_otp_length": 6})
        self.assertEqual(api.patches[1]["smtp_host"], "smtp-relay.brevo.com")
        self.assertEqual(api.patches[1]["smtp_pass"], "mot-de-passe-smtp")
        self.assertTrue(all(k.startswith(("mailer_templates_", "mailer_subjects_")) for k in api.patches[2]))
        secret_free(self, out)

    def test_smtp_a_jour_mot_de_passe_non_renvoye(self):
        state = dict(hac.desired(CONFIG), **SMTP_STATE)
        api = FakeApi(state)
        code, out = run(["--apply"], api, BREVO)
        self.assertEqual(code, 0, out)
        self.assertEqual(api.patches, [])
        self.assertIn("SMTP compris", out)

    def test_rotation_du_mot_de_passe(self):
        api = FakeApi(dict(hac.desired(CONFIG), **SMTP_STATE))
        code, out = run(["--apply", "--rotate-smtp-pass"], api, BREVO)
        self.assertEqual(code, 0, out)
        self.assertEqual([sorted(p) for p in api.patches], [sorted(hac.smtp_from_env(CONFIG, BREVO))])
        secret_free(self, out)

    def test_passage_a_resend(self):
        resend = {**BREVO, "SMTP_HOST": "smtp.resend.com", "SMTP_PORT": "465", "SMTP_USER": "resend"}
        api = FakeApi(dict(hac.desired(CONFIG), **SMTP_STATE))
        code, out = run(["--check"], api, resend)
        self.assertEqual(code, 1)
        self.assertIn("smtp : à mettre à jour (smtp_host, smtp_port, smtp_user, valeurs non affichées)", out)
        self.assertNotIn("smtp.resend.com", out)

    def test_apply_idempotent(self):
        api = FakeApi(dict(hac.desired(CONFIG), **SMTP_STATE))
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
            def __call__(self, method, ref, token, body=None, secrets=None):
                if method == "PATCH":
                    self.patches.append(dict(body))
                return dict(self.state)

        code, _ = run(["--apply"], Stubborn(dict(SMTP_STATE)))
        self.assertEqual(code, 1)

    def test_jeton_avec_retour_chariot_refuse_sans_l_afficher(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = hac.main(["--check"], {"SUPABASE_ACCESS_TOKEN": "jeton\r\njeton-suite", "SUPABASE_PROJECT_REF": "ref"})
        self.assertEqual(code, 2)
        self.assertNotIn("jeton", out.getvalue().replace("SUPABASE_ACCESS_TOKEN", ""))

    def test_jeton_avec_espaces_autour_accepte(self):
        api = FakeApi(dict(hac.desired(CONFIG), **SMTP_STATE))
        out = io.StringIO()
        with mock.patch.object(hac, "_request", api), contextlib.redirect_stdout(out):
            code = hac.main(["--check"], {"SUPABASE_ACCESS_TOKEN": " jeton\n", "SUPABASE_PROJECT_REF": "ref"})
        self.assertEqual(code, 0)

    def test_check_seuls_les_modeles_attendent_un_smtp(self):
        api = FakeApi(hac.desired_auth(CONFIG))
        code, out = run(["--check"], api)
        self.assertEqual(code, 3)
        self.assertIn("SMTP personnalisé", out)
        self.assertEqual(api.patches, [])

    def test_smtp_pousse_puis_modeles_encore_refuses(self):
        class Lagging(FakeApi):
            def __call__(self, method, ref, token, body=None, secrets=None):
                if method == "PATCH" and any(k.startswith("mailer_templates_") for k in body):
                    self.patches.append(dict(body))
                    raise hac.ApiError(400, ENTITLEMENT)
                return super().__call__(method, ref, token, body, secrets)

        api = Lagging(hac.desired_auth(CONFIG))
        code, out = run(["--apply"], api, BREVO)
        self.assertEqual(code, 3, out)
        self.assertIn("Relancer --apply dans quelques instants", out)
        self.assertNotIn("Définir SMTP_HOST", out)
        self.assertIn("Auth et SMTP relus conformes", out)
        secret_free(self, out)

    def test_rotation_sans_smtp_refusee(self):
        code, out = run(["--apply", "--rotate-smtp-pass"], FakeApi({}))
        self.assertEqual(code, 2)
        self.assertIn("SMTP_*", out)

    def test_check_annonce_la_rotation(self):
        api = FakeApi(dict(hac.desired(CONFIG), **SMTP_STATE))
        code, out = run(["--check", "--rotate-smtp-pass"], api, BREVO)
        self.assertEqual(code, 1)
        self.assertIn("mot de passe à renvoyer", out)

    def test_sans_jeton(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(hac.main(["--check"], {}), 2)

    def test_plan_sans_reseau(self):
        def no_network(*_, **__):
            raise AssertionError("appel réseau")

        code, out = run(["--plan"], no_network, BREVO)
        self.assertEqual(code, 0)
        self.assertIn("mailer_otp_length = 6", out)
        self.assertIn("smtp : depuis SMTP_*", out)
        secret_free(self, out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
