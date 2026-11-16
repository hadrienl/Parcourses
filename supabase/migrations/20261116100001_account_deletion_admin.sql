-- Suppression d'un compte par l'administration (#87, lot 87.8) : la page /supprimer-mes-donnees/ promet de supprimer
-- sur demande, par e-mail, le compte d'une personne qui n'a plus l'app. Supprimer l'utilisateur depuis le tableau de
-- bord effacerait ses listes partagées au lieu de les confier à un membre, et garderait son journal
-- d'authentification. accounts.delete_account fait exactement ce que fait delete_my_account, pour un compte donné, et
-- delete_my_account l'appelle désormais pour son appelant.
--
-- Réservée au rôle postgres (éditeur SQL du projet, après vérification que la demande vient de l'adresse du compte) :
--   select accounts.delete_account('<uuid du compte>');
-- Idempotente : relancer la migration redéfinit les deux fonctions.

create or replace function accounts.delete_account(p_user uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
begin
  if p_user is null or not exists (select 1 from auth.users as u where u.id = p_user) then
    raise exception 'unknown account' using errcode = 'P0002';
  end if;

  -- Verrou des membres des listes du compte : un héritier qui quitte la liste au même moment est attendu.
  perform 1 from public.list_members as m
  inner join public.lists as l on l.id = m.list_id
  where l.owner_id = p_user
  for update of m;

  -- Chaque liste partagée passe à l'éditeur le plus ancien, sinon au lecteur le plus ancien ; les autres partent avec
  -- le compte (cascade).
  with heirs as (
    select distinct on (m.list_id) m.list_id, m.user_id
    from public.list_members as m
    inner join public.lists as l on l.id = m.list_id
    where l.owner_id = p_user
    order by m.list_id, (m.role = 'editor') desc, m.created_at, m.user_id
  ),
  moved as (
    update public.lists as l set owner_id = h.user_id
    from heirs as h
    where l.id = h.list_id
    returning l.id, h.user_id
  )
  delete from public.list_members as m
  using moved
  where m.list_id = moved.id and m.user_id = moved.user_id;

  delete from auth.users as u where u.id = p_user;
  perform accounts.forget_audit_log(array[p_user]);
end;
$$;

revoke all on function accounts.delete_account(uuid) from public, anon, authenticated, service_role;

create or replace function public.delete_my_account()
returns void
language plpgsql
volatile
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  -- Second appel avec le même jeton (réponse perdue, nouvel essai de l'app) : le compte n'existe plus, rien à faire.
  if not exists (select 1 from auth.users as u where u.id = v_user) then
    return;
  end if;
  perform accounts.delete_account(v_user);
end;
$$;

revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;
