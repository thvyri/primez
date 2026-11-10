-- ============================================================================
-- PrimeZ — CLASSEMENTS
--  1) Les comptes admin (profiles.is_admin = true) n'apparaissent plus dans aucun
--     classement : Ballon d'Or, Ranked, Ligue des Champions, et les nouveaux.
--  2) Nouvelle fonction leaderboards() : tous les classements de l'onglet « Classements ».
-- À lancer une fois dans Supabase > SQL Editor. Peut être relancé sans risque.
-- ============================================================================

-- ---------- 1a) Ballon d'Or : rang de la semaine sans les admins ----------
create or replace function public._week_rank(p_user uuid, p_ws timestamptz, p_we timestamptz) returns int
language sql stable security definer set search_path = public as $$
  select r.rk::int from (
    select o.user_id, rank() over (order by sum(o.points) desc) rk
    from public.openings o
    join auth.users u on u.id = o.user_id and not coalesce(u.is_anonymous, false)
    join public.profiles p on p.id = o.user_id and not coalesce(p.is_admin, false)
    where o.created_at >= p_ws and o.created_at < p_we group by o.user_id) r
  where r.user_id = p_user
$$;

create or replace function public.weekly_leaderboard(p_week_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); ws timestamptz; we timestamptz; pws timestamptz; pwe timestamptz;
  lrk int; res jsonb;
begin
  select b.ws, b.we into ws, we from public._week_bounds(greatest(p_week_offset, 0)) b;
  select b.ws, b.we into pws, pwe from public._week_bounds(1) b;
  res := (
    with s as (
      select o.user_id, sum(coalesce(o.points, 0))::bigint pts, count(*) n
      from public.openings o
      join auth.users u on u.id = o.user_id and not coalesce(u.is_anonymous, false)
      join public.profiles pa on pa.id = o.user_id and not coalesce(pa.is_admin, false)
      where o.created_at >= ws and o.created_at < we group by o.user_id),
    r as (select s.*, rank() over (order by pts desc) rk from s)
    select jsonb_build_object(
      'week_start', ws, 'week_end', we,
      'rows', (select coalesce(jsonb_agg(jsonb_build_object('rank', t.rk, 'id', t.user_id, 'username', p.username, 'avatar', p.avatar_url,
                  'points', t.pts, 'openings', t.n, 'level', public.level_of(public.user_score(t.user_id)),
                  'reward', public._reward_for(t.rk::int)) order by t.rk, p.username), '[]'::jsonb)
               from (select * from r order by rk limit 50) t join public.profiles p on p.id = t.user_id),
      'me', (select jsonb_build_object('rank', rk, 'points', pts, 'openings', n) from r where user_id = uid),
      'players', (select count(*) from r),
      'hidden', coalesce((select is_admin from public.profiles where id = uid), false)));
  if p_week_offset <= 0 and uid is not null then
    lrk := public._week_rank(uid, pws, pwe);
    res := res || jsonb_build_object('last_week', jsonb_build_object(
      'rank', lrk, 'amount', case when lrk is null then 0 else public._reward_for(lrk) end,
      'claimed', exists (select 1 from public.weekly_rewards w where w.week_start = pws and w.user_id = uid)));
  end if;
  return res;
end $$;

-- ---------- 1b) Ligue des Champions : top 10 sans les admins ----------
create or replace function public.ldc_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r ldc_stats%rowtype; cl jsonb; tm int[]; pk int; top jsonb; rk int; today int;
begin
  if uid is null then raise exception 'Connecte-toi pour jouer'; end if;
  cl := _ldc_claim(uid); r := _ldc_row(uid);
  select cards into tm from ldc_teams where user_id = uid;
  select packs into pk from ldc_inv where user_id = uid;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into top from (
    select p.username, s.points, s.wins, s.losses, s.user_id = uid as me from ldc_stats s join profiles p on p.id = s.user_id
    where s.season = r.season and not coalesce(p.is_admin, false) order by s.points desc, s.wins desc limit 10) x;
  select count(*) + 1 into rk from ldc_stats s join profiles p on p.id = s.user_id
    where s.season = r.season and s.points > r.points and not coalesce(p.is_admin, false);
  select count(*) into today from ldc_matches where user_id = uid and created_at >= (_paris_today()::timestamp at time zone 'Europe/Paris');
  return jsonb_build_object('season', r.season, 'ends_at', _ldc_end(r.season), 'points', r.points, 'wins', r.wins, 'losses', r.losses,
    'streak', r.streak, 'best', r.best, 'rank', rk, 'team', tm, 'packs', coalesce(pk, 0), 'claimed', cl, 'top', top, 'today', today);
end $$;

-- ---------- 1c) Ranked : top et rang sans les admins (seulement si ranked.sql a déjà été lancé) ----------
do $do$
begin
  if to_regclass('public.ranked_players') is not null then
    execute $f$
    create or replace function public.ranked_state()
    returns jsonb language plpgsql security definer set search_path=public as $body$
    declare me public.ranked_players; v_rank int; v_total int;
    begin
      me := rk_me();
      select count(*)+1 into v_rank from ranked_players rp join profiles p on p.id=rp.user_id
        where rp.elo>me.elo and (rp.wins+rp.draws+rp.losses)>0 and not coalesce(p.is_admin,false);
      select count(*) into v_total from ranked_players rp join profiles p on p.id=rp.user_id
        where (rp.wins+rp.draws+rp.losses)>0 and not coalesce(p.is_admin,false);
      return jsonb_build_object(
        'elo',me.elo,'best',me.best_elo,'wins',me.wins,'draws',me.draws,'losses',me.losses,'streak',me.streak,
        'today',me.today,'won_today',me.won_today,'formation',me.formation,'cards',to_jsonb(me.cards),
        'rank',v_rank,'players',v_total,'cohesion',case when array_length(me.cards,1)=11 then rk_cohesion(me.cards) else 0 end,
        'top',coalesce((select jsonb_agg(t order by t.elo desc) from (
            select p.username, to_jsonb(p)->>'avatar_url' as avatar, rp.elo, rp.wins, rp.draws, rp.losses, rp.user_id=auth.uid() as me
            from ranked_players rp join profiles p on p.id=rp.user_id
            where (rp.wins+rp.draws+rp.losses)>0 and not coalesce(p.is_admin,false) order by rp.elo desc, rp.wins desc limit 50) t),'[]'::jsonb),
        'recent',coalesce((select jsonb_agg(m order by m.created_at desc) from (
            select opp_name, opp_elo, my_score, opp_score, elo_after-elo_before as delta, reward, created_at
            from ranked_matches where user_id=auth.uid() and status='done' order by created_at desc limit 8) m),'[]'::jsonb)
      );
    end $body$;
    $f$;
  end if;
end $do$;

-- ---------- 2) Tous les classements de l'onglet « Classements » ----------
-- Chaque classement : top 10, nombre de joueurs classés, et la place du joueur connecté.
-- Sont exclus : les invités (comptes anonymes) et les comptes admin.
create or replace function public.leaderboards() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); res jsonb; rkb jsonb;
begin
  with elig as (
    select p.id, p.username, p.avatar_url, p.balloons
    from profiles p join auth.users u on u.id = p.id
    where not coalesce(u.is_anonymous, false) and not coalesce(p.is_admin, false)),
  col as (
    select uc.user_id, count(*)::bigint v,
           count(*) filter (where c.rarity in ('mythique','promo','prime','goat'))::bigint rare,
           coalesce(sum(card_points(c.rarity)), 0)::bigint score
    from user_cards uc join cards c on c.id = uc.card_id where uc.quantity > 0 group by uc.user_id),
  allv as (
    select 'collection' k, user_id, v from col
    union all select 'rares', user_id, rare from col where rare > 0
    union all select 'score', user_id, score from col where score > 0
    union all select 'opened', user_id, count(*)::bigint from openings group by user_id
    union all select 'week', o.user_id, sum(coalesce(o.points, 0))::bigint from openings o, _week_bounds(0) b
                where o.created_at >= b.ws and o.created_at < b.we group by o.user_id having sum(coalesce(o.points, 0)) > 0
    union all select 'refs', inviter, count(*)::bigint from referrals where rewarded_at is not null group by inviter
    union all select 'ldc', user_id, points::bigint from ldc_stats where season = (select max(season) from ldc_stats) and points > 0
    union all select 'rich', id, balloons::bigint from elig where balloons > 0),
  r as (
    select a.k, a.user_id, a.v, e.username, e.avatar_url,
           rank() over (partition by a.k order by a.v desc) rk, count(*) over (partition by a.k) n
    from allv a join elig e on e.id = a.user_id)
  select jsonb_object_agg(k, b) into res from (
    select k, jsonb_build_object(
      'players', max(n),
      'rows', coalesce(jsonb_agg(jsonb_build_object('rank', rk, 'id', user_id, 'username', username, 'avatar', avatar_url, 'value', v)
                order by rk, username) filter (where rk <= 10), '[]'::jsonb),
      'me', (jsonb_agg(jsonb_build_object('rank', rk, 'value', v)) filter (where user_id = uid)) -> 0) b
    from r group by k) x;

  -- Ranked : à part, pour que tout le reste marche même si ranked.sql n'a pas encore été lancé
  begin
    with r as (
      select rp.user_id, rp.elo::bigint v, p.username, p.avatar_url,
             rank() over (order by rp.elo desc) rk, count(*) over () n
      from ranked_players rp join profiles p on p.id = rp.user_id join auth.users u on u.id = p.id
      where (rp.wins + rp.draws + rp.losses) > 0 and not coalesce(u.is_anonymous, false) and not coalesce(p.is_admin, false))
    select jsonb_build_object(
      'players', coalesce(max(n), 0),
      'rows', coalesce(jsonb_agg(jsonb_build_object('rank', rk, 'id', user_id, 'username', username, 'avatar', avatar_url, 'value', v)
                order by rk, username) filter (where rk <= 10), '[]'::jsonb),
      'me', (jsonb_agg(jsonb_build_object('rank', rk, 'value', v)) filter (where user_id = uid)) -> 0)
    into rkb from r;
  exception when undefined_table then rkb := null;
  end;

  res := coalesce(res, '{}'::jsonb);
  if rkb is not null and (rkb->>'players')::int > 0 then res := res || jsonb_build_object('ranked', rkb); end if;
  return jsonb_build_object(
    'boards', res,
    'total_cards', (select count(*) from cards),
    'hidden', coalesce((select is_admin from profiles where id = uid), false));
end $$;

revoke all on function public.leaderboards() from public, anon;
grant execute on function public.leaderboards() to authenticated;

notify pgrst, 'reload schema';
