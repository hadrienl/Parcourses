-- Planification du calcul du graphe (issue #11, §5). Les jobs tournent sous le rôle postgres.
-- graph-snapshot-decay tourne à 03:32 : hors des minutes multiples de 5 de graph-snapshot,
-- avec lequel il partage un verrou consultatif ; seuil de 23 h pour ne pas manquer le passage quotidien.
-- cron.schedule remplace un job existant du même nom : migration idempotente.
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

select cron.schedule('graph-process', '* * * * *', 'select graph.process_pending_visits(200)');
select cron.schedule('graph-close-stale', '*/5 * * * *', 'select graph.close_stale_visits()');
select cron.schedule('graph-snapshot', '*/5 * * * *', 'select graph.publish_snapshots(50)');
select cron.schedule(
  'graph-snapshot-decay', '32 3 * * *',
  $$select graph.publish_snapshots(10000, now(), interval '23 hours')$$
);
select cron.schedule(
  'graph-runs-purge', '15 4 * * *',
  $$delete from graph.runs where started_at < now() - interval '30 days';
    delete from cron.job_run_details where end_time < now() - interval '30 days'$$
);
