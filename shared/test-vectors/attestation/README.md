# Vecteurs de l'attestation d'appareil (#137)

Les deux apps décident de la même façon quand tenter l'attestation (App Attest sur iOS, Play Integrity sur Android),
comment lire la réponse de l'Edge Function `attest-device` et quand réessayer. Ces décisions sont des **fonctions
pures** regroupées sous le même nom sur les deux plateformes, `AttestationDecisions` (Swift : `enum`, Kotlin :
`object`). Chaque fichier `NNN-*.json` décrit une fonction (`function`) et ses cas (`cases`, `input` → `expected`).
Les tests des deux apps lisent **tous** les fichiers de ce dossier et échouent sur une fonction inconnue.

Conception : commentaire de conception de #137. Dates ISO 8601 UTC.

| Fichier | Fonction | Entrée → sortie |
| --- | --- | --- |
| `001` | `shouldAttempt(isAnonymous, state, now)` | `Bool` |
| `002` | `nextState(outcome, now)` | `AttestationState` |
| `003` | `responseOutcome(step, httpStatus, status, error)` | `proceed` \| `AttestationOutcome` |

## Noms communs

- `AttestationState` : `status` (`pending`, `attested`, `unsupported`) et `nextAttemptAt` (date ou nul), persisté
  **par compte** (id utilisateur) ; aucun état = première tentative.
- `AttestationOutcome` : `attested`, `unsupported`, `transient`, `notConfigured`, `rejected`.
- `AttestationStep` : `challenge`, `verify`.
- Délais : `transient` 1 h, `notConfigured` 24 h, `rejected` 7 jours.

## Protocole (Edge Function `attest-device`, JWT de l'utilisateur)

1. `POST {"step": "challenge", "platform": "ios" | "android"}` → `200 {"status": "challenge", "challenge": "<43
   caractères base64url>"}`, ou `200 {"status": "attested"}` (déjà fait), ou `200 {"status": "not_configured"}`.
2. iOS : `generateKey()`, puis `attestKey(keyId, clientDataHash: SHA-256(UTF-8 du défi))`. Android :
   `requestIntegrityToken` avec `nonce = défi`, tel quel.
3. `POST {"step": "verify", "platform": "ios", "challenge", "key_id": "<keyId base64 standard, tel que rendu par
   generateKey>", "attestation": "<objet d'attestation en base64 standard>"}` ou `{"step": "verify", "platform":
   "android", "challenge", "token": "<jeton Play Integrity>"}` → `200 {"status": "attested"}`, `400 {"error":
   "invalid_challenge" | "rejected" | "invalid_body"}`, `502 {"error": "upstream_unavailable"}`.

Un défi sert une seule fois, même en cas d'échec, et expire au bout de 10 minutes.
