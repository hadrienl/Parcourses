-- Rétention du journal d'authentification à 90 jours (#68).
begin;
\ir 00_helpers.psql
select plan(8);

select ok(not has_function_privilege('authenticated', 'accounts.purge_audit_log(timestamptz, interval)', 'EXECUTE'),
  'purge du journal non exécutable par authenticated');
select ok(not has_function_privilege('anon', 'accounts.purge_audit_log(timestamptz, interval)', 'EXECUTE'),
  'purge du journal non exécutable par anon');
select is((select proconfig from pg_proc where oid = 'accounts.purge_audit_log(timestamptz, interval)'::regprocedure),
  array['search_path=""'], 'search_path vide');

-- Trois lignes : 91 jours, 89 jours, aujourd'hui.
insert into auth.audit_log_entries (id, payload, created_at) values
  ('00000000-0000-0000-0000-00000000a091', '{"action": "login"}', now() - interval '91 days'),
  ('00000000-0000-0000-0000-00000000a089', '{"action": "login"}', now() - interval '89 days'),
  ('00000000-0000-0000-0000-00000000a000', '{"action": "login"}', now());

select throws_ok($$ select accounts.purge_audit_log(now(), interval '1 day') $$, '22023', null, 'rétention trop courte refusée');
select ok(accounts.purge_audit_log() >= 1, 'au moins une ligne purgée');
select is((select count(*)::int from auth.audit_log_entries where id = '00000000-0000-0000-0000-00000000a091'), 0,
  'ligne de plus de 90 jours supprimée');
select is((select count(*)::int from auth.audit_log_entries
           where id in ('00000000-0000-0000-0000-00000000a089', '00000000-0000-0000-0000-00000000a000')), 2,
  'lignes de moins de 90 jours gardées');

select is((select schedule from cron.job where jobname = 'accounts-audit-retention'), '52 4 * * *', 'purge planifiée chaque nuit');

select * from finish();
rollback;
