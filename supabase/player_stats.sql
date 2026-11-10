-- =====================================================================
--  PrimeZ · stats des joueurs affichées au dos des cartes (matchs, buts, passes décisives)
--  À exécuter une fois dans Supabase : SQL Editor → New query → coller → Run.
--  Tout le monde peut lire ; seuls les admins modifient (bouton ✎ au dos d'une carte, en admin).
--  Sans ligne pour un joueur, le site prend Wikidata (souvent en retard pour les joueurs en activité).
-- =====================================================================
create table if not exists public.player_stats (
  key         text primary key,          -- nom de la carte sans la saison, ex. « C.RONALDO »
  matches     int,
  goals       int,
  assists     int,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
alter table public.player_stats enable row level security;
drop policy if exists "player_stats lecture" on public.player_stats;
create policy "player_stats lecture" on public.player_stats for select using (true);
grant select on public.player_stats to anon, authenticated;

create or replace function public.set_player_stats(p_key text, p_matches int, p_goals int, p_assists int)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not coalesce((select is_admin from profiles where id=auth.uid()),false) then raise exception 'Réservé aux admins'; end if;
  insert into player_stats(key,matches,goals,assists,updated_at,updated_by) values (upper(trim(p_key)),p_matches,p_goals,p_assists,now(),auth.uid())
  on conflict (key) do update set matches=excluded.matches, goals=excluded.goals, assists=excluded.assists, updated_at=now(), updated_by=auth.uid();
end $$;
grant execute on function public.set_player_stats(text,int,int,int) to authenticated;
