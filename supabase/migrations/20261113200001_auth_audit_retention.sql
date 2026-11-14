-- Rétention du journal d'authentification à 90 jours (#68, décision du 13 novembre 2026).
-- GoTrue ne purge jamais auth.audit_log_entries, qui garde l'id du compte et l'adresse IP de chaque
-- connexion. delete_my_account() et la purge des comptes inactifs en effacent déjà les lignes d'un compte
-- supprimé ; ce job borne aussi la conservation pour les comptes actifs. Sur le projet hébergé, GoTrue
-- n'écrit pas ce journal en base (0 ligne) : le job ne coûte alors qu'une lecture de table vide.

-- Supprime les lignes plus anciennes que la rétention (et celles sans date), par lots de 10 000, au plus
-- p_max_batches lots par passage : un premier passage sur un gros historique ne tient pas une seule énorme
-- transaction ; le reste part les nuits suivantes. La table n'a pas d'index utile : chaque lot la lit, ce qui
-- est acceptable une fois par nuit. Droits du rôle propriétaire (BYPASSRLS, DELETE sur auth.audit_log_entries) :
-- vérifiés par la garde de 20261113140001_account_deletion.sql. Appelée par pg_cron sous le rôle postgres.
-- Première version de travail, à deux paramètres : jamais livrée, retirée pour qu'un appel sans argument reste univoque.
drop function if exists accounts.purge_audit_log(timestamptz, interval);

create or replace function accounts.purge_audit_log(
  p_now timestamptz default now(),
  p_retention interval default interval '90 days',
  p_max_batches integer default 50
)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_batch integer;
  v_deleted integer := 0;
begin
  if p_retention < interval '30 days' or p_max_batches < 1 then
    raise exception 'invalid audit log retention' using errcode = '22023';
  end if;

  for i in 1..p_max_batches loop
    delete from auth.audit_log_entries as e
    where e.id in (
      select a.id from auth.audit_log_entries as a
      where a.created_at < p_now - p_retention or a.created_at is null
      limit 10000
    );
    get diagnostics v_batch = row_count;
    v_deleted := v_deleted + v_batch;
    exit when v_batch < 10000;
  end loop;
  return v_deleted;
end;
$$;

revoke all on function accounts.purge_audit_log(timestamptz, interval, integer) from public, anon, authenticated;

-- Une fois par nuit, à 04:52 UTC : après graph-runs-purge (04:15), hors des minutes des autres jobs.
-- cron.schedule remplace un job du même nom : migration idempotente.
select cron.schedule('accounts-audit-retention', '52 4 * * *', 'select accounts.purge_audit_log()');
