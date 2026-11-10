-- ============================================================================
-- PrimeZ — MISE À JOUR : Ranked, joueurs en ligne, recherche de joueurs (admin)
-- À lancer une fois dans Supabase > SQL Editor, APRÈS ranked.sql. Relançable sans risque.
-- ============================================================================

-- ---------- 1) Ranked : l'adversaire est toujours un club IA à ta mesure ----------
-- Avant : le jeu faisait jouer le onze enregistré d'un autre joueur à sa place
-- (un débutant pouvait tomber contre le compte admin et prendre 3-0).
create or replace function public.ranked_start()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  me public.ranked_players; opp record; v_opp_cards int[]; v_opp_name text; v_opp_elo int; v_opp_user uuid; pa numeric; pb numeric;
  i int; n_att int; sides text[]; mins int[]; mom jsonb:='[]'; side text; v_mid bigint; live bigint; acts text[]:=array['F','D','P'];
  bots text[]:=array['Racing Pixel','AS Algorithme','Olympique Binaire','FC Neurone','Sporting Silicium','Dynamo Data','Real Robot','Inter Circuit','Atlético Code','Union Cyber'];
begin
  me := rk_me();
  if coalesce(array_length(me.cards,1),0)<>11 then raise exception 'Compose ton onze avant de jouer'; end if;
  if (select count(*) from user_cards where user_id=auth.uid() and card_id=any(me.cards) and quantity>0)<>11 then
    raise exception 'Une carte de ton onze n''est plus dans ta collection : modifie ton équipe'; end if;
  -- un match laissé en plan compte comme une défaite
  for live in select id from ranked_matches where user_id=auth.uid() and status='live' loop perform rk_finalize(live,true); end loop;
  me := rk_me();
  if me.today>=60 then raise exception 'Limite de 60 matchs classés par jour atteinte, reviens demain'; end if;

  pa := rk_team_power(me.cards);
  -- Adversaire : toujours un club IA taillé à ta mesure. On ne fait plus jouer le onze d'un autre
  -- joueur à sa place (personne ne « perd » ou ne « gagne » sans avoir lancé le match).
  v_opp_user:=null; v_opp_elo:=greatest(600, me.elo + (floor(random()*121)-60)::int); v_opp_name:=bots[1+floor(random()*array_length(bots,1))::int];
  select array_agg(id) into v_opp_cards from (select id from cards where coalesce(active,true) and rk_card_rating(rarity,name) between pa-6 and pa+5 order by random() limit 11) z;
  if coalesce(array_length(v_opp_cards,1),0)<11 then
    select array_agg(id) into v_opp_cards from (select id from cards order by abs(rk_card_rating(rarity,name)-pa), random() limit 11) z;
  end if;
  pb := rk_team_power(v_opp_cards);

  -- 8 temps forts : l'équipe la plus forte a un peu plus d'occasions
  n_att := greatest(2, least(6, round(4 + (pa-pb)/4.0)::int));
  select array_agg(x order by random()) into sides from (select 'att'::text x from generate_series(1,n_att) union all select 'def' from generate_series(1,8-n_att)) z;
  select array_agg(m order by m) into mins from (select distinct (3+floor(random()*86))::int m from generate_series(1,30) limit 8) z;
  for i in 1..8 loop
    side := sides[i];
    mom := mom || jsonb_build_object('m',coalesce(mins[i],i*10),'side',side,
      'actor', case when side='att' then me.cards[7+floor(random()*5)::int] else v_opp_cards[7+floor(random()*5)::int] end,
      'foe',   case when side='att' then v_opp_cards[1+floor(random()*6)::int] else me.cards[1+floor(random()*6)::int] end,
      'hid',   acts[1+floor(random()*3)::int]);
  end loop;

  insert into ranked_matches(user_id,opp_user,opp_name,opp_elo,opp_cards,my_cards,my_score,opp_score,events,elo_before,elo_after,reward,status,step,moments,my_power,opp_power)
  values (auth.uid(),v_opp_user,v_opp_name,v_opp_elo,v_opp_cards,me.cards,0,0,'[]',me.elo,me.elo,0,'live',0,mom,pa,pb) returning id into v_mid;
  return (select rk_public(m) from ranked_matches m where id=v_mid);
end $$;

-- ---------- 2) Joueurs en ligne (panneau admin) ----------
-- « En ligne » = actif dans les 3 dernières minutes (le site signale l'activité toutes les 60 s).
create or replace function public.admin_online() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d0 timestamptz := (date_trunc('day', now() at time zone 'Europe/Paris')) at time zone 'Europe/Paris';
begin
  if not coalesce((select is_admin from profiles where id = auth.uid()), false) then raise exception 'Réservé à l''admin'; end if;
  return jsonb_build_object(
    'count', (select count(*) from profiles where last_seen > now() - interval '3 minutes'),
    'today', (select count(*) from profiles where last_seen >= d0),
    'total', (select count(*) from profiles p join auth.users u on u.id = p.id where not coalesce(u.is_anonymous, false)),
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'username', coalesce(x.username, 'Invité'),
                  'guest', x.guest, 'seen', x.last_seen) order by x.last_seen desc)
                from (select p.id, p.username, p.last_seen, coalesce(u.is_anonymous, false) guest
                      from profiles p join auth.users u on u.id = p.id
                      where p.last_seen > now() - interval '3 minutes' order by p.last_seen desc limit 100) x), '[]'::jsonb));
end $$;
revoke all on function public.admin_online() from public, anon;
grant execute on function public.admin_online() to authenticated;

-- ---------- 3) Recherche de joueurs (cadeaux) : distinguer les comptes qui ont le même pseudo ----------
-- Deux comptes peuvent porter le même pseudo (un compte invité et un compte Discord, par exemple) :
-- la recherche indique maintenant si c'est un invité et sa dernière activité, comptes Discord en premier.
drop function if exists public.admin_find_players(text);
create function public.admin_find_players(p_q text)
returns table (id uuid, username text, balloons int, created_at timestamptz, guest boolean, last_seen timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé aux admins'; end if;
  return query select p.id, p.username, p.balloons, p.created_at, coalesce(u.is_anonymous, false), p.last_seen
    from public.profiles p join auth.users u on u.id = p.id
    where p.username ilike '%' || coalesce(p_q, '') || '%'
    order by coalesce(u.is_anonymous, false), p.last_seen desc nulls last limit 30;
end $$;
revoke all on function public.admin_find_players(text) from public, anon;
grant execute on function public.admin_find_players(text) to authenticated;

notify pgrst, 'reload schema';
