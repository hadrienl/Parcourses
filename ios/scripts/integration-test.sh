#!/usr/bin/env bash
# Tests d'intégration contre le Supabase LOCAL (ports 563xx), qui doit être démarré.
# Usage, depuis ios/ : scripts/integration-test.sh
# Variable facultative SIMULATOR_UDID : réutilise ce simulateur au lieu du dernier runtime.
set -euo pipefail

status=$(cd .. && supabase status -o env 2>/dev/null)
value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" <<<"$status"; }
url=$(value API_URL)
key=$(value PUBLISHABLE_KEY)
# Mailpit reçoit les codes de connexion (#87) ; le test les y lit.
mailpit=$(value MAILPIT_URL)
mailpit=${mailpit:-http://127.0.0.1:56324}

if [[ "$url" != "http://127.0.0.1:56321" || -z "$key" ]]; then
  echo "Supabase local introuvable (attendu sur 127.0.0.1:56321) : lancer supabase start." >&2
  exit 1
fi

sql() { docker exec -i supabase_db_parcourses psql -U postgres -v ON_ERROR_STOP=1 -Atq; }

# Un magasin dédié au test, en plein océan pour que nearby_stores ne le propose pas aux autres tests : instantané publié avec les vrais paramètres appareil, retiré à la fin.
store=9f000000-0000-4000-8000-000000000909
cleanup() {
  sql <<SQL
-- Comptes e-mail des tests (#87) : un compte e-mail n'est jamais purgé pour inactivité.
delete from auth.users where email like 'it-87-%@example.com';
drop trigger if exists it_fail_list on public.lists;
drop function if exists public.it_fail_list();
delete from public.visits where store_id = '$store';
delete from public.store_graph_snapshots where store_id = '$store';
delete from public.stores where id = '$store';
SQL
}
# Edge Function send-invitation (#87, lot 87.4) : l'image Edge Runtime manque en local, elle tourne avec Deno, comme
# dans supabase/tests/e2e/sharing.test.ts. Sans Deno, le test passe par create_invitation (sans e-mail).
function_port=54988
function_pid=
stop_function() {
  [[ -n "$function_pid" ]] && kill "$function_pid" 2>/dev/null || true
}
cleanup
trap 'stop_function; cleanup' EXIT
send_invitation=
if command -v deno >/dev/null; then
  # Depuis ios/ : la racine du dépôt est le dossier parent. `exec` : le PID gardé est celui de Deno.
  (cd .. && SUPABASE_URL="$url" SUPABASE_ANON_KEY="$key" MAILPIT_API_URL="$mailpit" \
    SEND_INVITATION_PORT="$function_port" \
    exec deno run --allow-net=127.0.0.1 --allow-env supabase/functions/send-invitation/index.ts >/dev/null 2>&1) &
  function_pid=$!
  for _ in $(seq 1 100); do
    status_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$function_port" || true)
    if [[ "$status_code" == 405 ]]; then
      send_invitation="http://127.0.0.1:$function_port"
      break
    fi
    sleep 0.1
  done
  [[ -n "$send_invitation" ]] || echo "send-invitation ne répond pas : le test passera par create_invitation" >&2
fi
# Erreur serveur sur une seule ligne, pour la mise de côté. Local et temporaire : retirée par cleanup.
sql <<SQL
create function public.it_fail_list() returns trigger language plpgsql as \$\$
begin
  if new.name = 'IT-500' then raise exception 'panne simulée' using errcode = 'XX000'; end if;
  return new;
end;
\$\$;
create trigger it_fail_list before insert or update on public.lists
  for each row execute function public.it_fail_list();
SQL
sql <<SQL
insert into public.stores (id, name, location, organic_aisle)
values ('$store', 'Magasin de test', extensions.st_setsrid(extensions.st_makepoint(-30.0, 40.0), 4326)::extensions.geography, true);
insert into public.store_graph_snapshots
  (store_id, snapshot_version, algo_version, generated_at, checked_at, etag, payload, payload_bytes)
select '$store', 1000, a.version, now(), now(), 'it', p.payload, octet_length(p.payload::text)
from graph.active_version() as a
cross join lateral (select jsonb_build_object(
  'format_version', 1, 'store_id', '$store', 'algo_version', a.version, 'params_version', a.version,
  'params', a.device_params, 'snapshot_version', 1000, 'generated_at', '2026-11-01T00:00:00Z',
  'confidence_q', 720, 'entries', '[]'::jsonb, 'edges', '[]'::jsonb) as payload) as p;
-- Public compté (#70, lot 70.3) : sans lui, la RPC ne sert l'instantané à personne. Retiré avec l'instantané.
insert into graph.snapshot_audience (store_id, contributors) values ('$store', 2);
SQL

# Suppression du compte (#68) : le test y écrit l'ancien compte, le nouveau et la visite, vérifiés en base à la fin.
deletion_out=$(mktemp -d)/accounts
# Comptes e-mail (#87) : l'ancien compte anonyme du second téléphone, supprimé après la reprise.
accounts_out=$(mktemp -d)/email-accounts
udid=${SIMULATOR_UDID:-$(scripts/simulator.sh latest)}
xcodegen generate --quiet
TEST_RUNNER_PARCOURSES_IT_URL="$url" TEST_RUNNER_PARCOURSES_IT_KEY="$key" \
  TEST_RUNNER_PARCOURSES_IT_SNAPSHOT_STORE="$store" TEST_RUNNER_PARCOURSES_IT_DELETION_OUT="$deletion_out" \
  TEST_RUNNER_PARCOURSES_IT_MAILPIT="$mailpit" TEST_RUNNER_PARCOURSES_IT_ACCOUNTS_OUT="$accounts_out" \
  TEST_RUNNER_PARCOURSES_IT_SEND_INVITATION="$send_invitation" \
  xcodebuild test -project Parcourses.xcodeproj -scheme Parcourses -destination "id=$udid" \
  -derivedDataPath DerivedData -only-testing:ParcoursesTests

# Ce que le serveur a réellement reçu : la coche annulée n'y est pas, le rayon bio non plus. L'article saisi
# librement a reçu son produit avant l'envoi : la coche désigne ce produit, classé dans sa catégorie.
result=$(sql <<SQL
select v.list_was_sorted, v.ended_at is not null, count(c.id), string_agg(coalesce(k.slug, pk.slug), ','),
       bool_and(c.product_id is not null)
from public.visits as v
left join public.checks as c on c.visit_id = v.id
left join public.categories as k on k.id = c.category_id
left join public.products as p on p.id = c.product_id
left join public.categories as pk on pk.id = p.category_id
where v.store_id = '$store'
group by v.id;
SQL
)
echo "Visite reçue : $result"
[[ "$result" == "t|t|1|dairy|t" ]] || { echo "Attendu : t|t|1|dairy|t" >&2; exit 1; }

# Suppression du compte : l'ancien compte n'existe plus, ni ses listes, visites et coches ; le nouveau existe et
# n'a aucune ligne. Les identifiants sont des UUID écrits par le test, jamais une saisie.
[[ -s "$deletion_out" ]] || { echo "Identifiants de la suppression absents ($deletion_out)" >&2; exit 1; }
read -r old_account new_account deleted_visit <"$deletion_out"
for id in "$old_account" "$new_account" "$deleted_visit"; do
  [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Identifiant illisible : $id" >&2; exit 1; }
done
deletion=$(sql <<SQL
select (select count(*) from auth.users where id = '$old_account'),
       (select count(*) from auth.users where id = '$new_account'),
       (select count(*) from public.lists where owner_id in ('$old_account', '$new_account')),
       (select count(*) from public.visits where user_id in ('$old_account', '$new_account')),
       (select count(*) from public.checks where visit_id = '$deleted_visit');
SQL
)
echo "Suppression du compte : $deletion"
[[ "$deletion" == "0|1|0|0|0" ]] || { echo "Attendu : 0|1|0|0|0" >&2; exit 1; }

# Comptes e-mail : l'ancien compte anonyme rattrapé par la connexion a été supprimé avec son jeton, et le compte e-mail
# du test aussi (nettoyage).
[[ -s "$accounts_out" ]] || { echo "Identifiants des comptes e-mail absents ($accounts_out)" >&2; exit 1; }
read -r left_anonymous email_account <"$accounts_out"
for id in "$left_anonymous" "$email_account"; do
  [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Identifiant illisible : $id" >&2; exit 1; }
done
accounts=$(sql <<SQL
select (select count(*) from auth.users where id = '$left_anonymous'),
       (select count(*) from auth.users where id = '$email_account');
SQL
)
echo "Comptes e-mail : $accounts"
[[ "$accounts" == "0|0" ]] || { echo "Attendu : 0|0" >&2; exit 1; }
