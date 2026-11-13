-- Rétention du journal d'authentification à 90 jours (#68, décision du 13 novembre 2026).
-- GoTrue ne purge jamais auth.audit_log_entries, qui garde l'id du compte et l'adresse IP de chaque
-- connexion. delete_my_account() et la purge des comptes inactifs en effacent déjà les lignes d'un compte
-- supprimé ; ce job borne aussi la conservation pour les comptes actifs. Sur le projet hébergé, GoTrue
-- n'écrit pas ce journal en base (0 ligne) : le job ne coûte alors qu'une lecture de table vide.

-- Supprime les lignes plus anciennes que la rétention. Volatile, appelée par pg_cron sous le rôle postgres.
create or replace function accounts.purge_audit_log(
  p_now timestamptz default now(),
  p_retention interval default interval '90 days'
)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  if p_retention < interval '30 days' then
    raise exception 'invalid audit log retention' using errcode = '22023';
  end if;

  delete from auth.audit_log_entries as e
  where e.created_at < p_now - p_retention;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function accounts.purge_audit_log(timestamptz, interval) from public, anon, authenticated;

-- Une fois par nuit, à 04:52 UTC : après graph-runs-purge (04:15), hors des minutes des autres jobs.
-- cron.schedule remplace un job du même nom : migration idempotente.
select cron.schedule('accounts-audit-retention', '52 4 * * *', 'select accounts.purge_audit_log()');
