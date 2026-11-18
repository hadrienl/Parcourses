// Clés d'API fournies aux Edge Functions (#114). Le projet hébergé donne les nouvelles clés dans deux dictionnaires JSON,
// SUPABASE_PUBLISHABLE_KEYS et SUPABASE_SECRET_KEYS ({"default": "sb_…"}), à côté des clés historiques SUPABASE_ANON_KEY
// et SUPABASE_SERVICE_ROLE_KEY, valables jusqu'à fin 2026. Les nouvelles d'abord : les historiques peuvent être coupées.

// Lecture de l'environnement, injectable pour les tests sans droit --allow-env (review-sign-in, #149).
export type EnvReader = (name: string) => string | undefined;
const processEnv: EnvReader = (name) => Deno.env.get(name);

function fromDictionary(name: string, env: EnvReader): string | undefined {
  const raw = env(name);
  if (!raw) return undefined;
  try {
    const value = (JSON.parse(raw) as Record<string, unknown>).default;
    return typeof value === "string" && value ? value : undefined;
  } catch {
    return undefined;
  }
}

export const publishableKey = (env: EnvReader = processEnv): string | undefined =>
  fromDictionary("SUPABASE_PUBLISHABLE_KEYS", env) ?? env("SUPABASE_ANON_KEY");

export const secretKey = (env: EnvReader = processEnv): string | undefined =>
  fromDictionary("SUPABASE_SECRET_KEYS", env) ?? env("SUPABASE_SERVICE_ROLE_KEY");

// En-têtes d'un appel à l'API avec une clé : une nouvelle clé (sb_…) va dans apikey seul (dans Authorization, la
// plateforme la lirait comme un JWT et refuserait) ; une clé historique (JWT) aussi dans Authorization.
export const keyHeaders = (key: string): Record<string, string> => ({
  apikey: key,
  ...(key.startsWith("sb_") ? {} : { Authorization: `Bearer ${key}` }),
});
