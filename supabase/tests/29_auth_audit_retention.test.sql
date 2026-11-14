-- Rétention du journal d'authentification à 90 jours (#68).
begin;
\ir 00_helpers.psql
select plan(10);

select ok(not has_function_privilege('authenticated', 'accounts.purge_audit_log(timestamptz, interval, integer)', 'EXECUTE'),
  'purge du journal non exécutable par authenticated');
select ok(not has_function_privilege('anon', 'accounts.purge_audit_log(timestamptz, interval, integer)', 'EXECUTE'),
  'purge du journal non exécutable par anon');
select is((select proconfig from pg_proc where oid = 'accounts.purge_audit_log(timestamptz, interval, integer)'::regprocedure),
  array['search_path=""'], 'search_path vide');

-- Lignes : 90 jours et une seconde, sans date, 90 jours moins une seconde, aujourd'hui.
insert into auth.audit_log_entries (id, payload, created_at) values
  ('00000000-0000-0000-0000-00000000a091', '{"action": "login"}', now() - interval '90 days 1 second'),
  ('00000000-0000-0000-0000-00000000a0ff', '{"action": "login"}', null),
  ('00000000-0000-0000-0000-00000000a089', '{"action": "login"}', now() - interval '89 days 23 hours 59 minutes 59 seconds'),
  ('00000000-0000-0000-0000-00000000a000', '{"action": "login"}', now());

select throws_ok($$ select accounts.purge_audit_log(now(), interval '1 day') $$, '22023', null, 'rétention trop courte refusée');
select throws_ok($$ select accounts.purge_audit_log(now(), interval '90 days', 0) $$, '22023', null, 'aucun lot refusé');
select ok(accounts.purge_audit_log() >= 2, 'au moins deux lignes purgées');
select is((select count(*)::int from auth.audit_log_entries where id = '00000000-0000-0000-0000-00000000a091'), 0,
  'ligne de plus de 90 jours supprimée');
select is((select count(*)::int from auth.audit_log_entries where id = '00000000-0000-0000-0000-00000000a0ff'), 0,
  'ligne sans date supprimée');
select is((select count(*)::int from auth.audit_log_entries
           where id in ('00000000-0000-0000-0000-00000000a089', '00000000-0000-0000-0000-00000000a000')), 2,
  'lignes de moins de 90 jours gardées');

select is((select schedule || ' ' || command || ' ' || username from cron.job where jobname = 'accounts-audit-retention'),
  '52 4 * * * select accounts.purge_audit_log() postgres', 'purge planifiée chaque nuit, sous postgres');

select * from finish();
rollback;
