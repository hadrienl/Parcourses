begin;
\ir 00_helpers.psql
select plan(2);

-- Échoue dès qu'une table de public oublie la RLS.
select is_empty($$
  select c.relname from pg_class as c
  join pg_namespace as n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity
$$, 'RLS active sur toutes les tables de public');

select is((select count(*)::int from pg_class as c join pg_namespace as n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r'), 10, '10 tables dans public');

select * from finish();
rollback;
