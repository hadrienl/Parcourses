// Edge Function review-sign-in (#149) : connexion des relecteurs d'Apple et de Google au compte de revue, avec une
// adresse et un code fixes. Contrat et sûreté : handler.ts. Réglage, secrets et remise à zéro :
// docs/hosted-supabase.md, « Compte de revue des stores ».
//
// Secret : REVIEW_SIGN_IN_CODE (6 chiffres). Sans lui, la fonction refuse tout, sans toucher la base.

import { safeHandleReviewSignIn } from "./handler.ts";

const env = (name: string) => Deno.env.get(name);
const handle = (request: Request) => safeHandleReviewSignIn(request, env, fetch);

// REVIEW_SIGN_IN_PORT : seulement pour le test de bout en bout, qui lance la fonction avec Deno contre la pile locale.
const port = Deno.env.get("REVIEW_SIGN_IN_PORT");
if (port) {
  Deno.serve({ port: Number(port), hostname: "127.0.0.1" }, handle);
} else {
  Deno.serve(handle);
}
