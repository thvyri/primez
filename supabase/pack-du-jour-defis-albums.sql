-- PrimeZ · pack du jour (série de 7 jours), nouveaux défis de la semaine, albums à compléter
-- À lancer une fois dans Supabase > SQL Editor (après 14-missions, 22-parrainage, 23-promo et ranked).
-- On peut le relancer sans risque : il remplace les fonctions et met à jour les albums.
--
-- Pack du jour : chaque jour, 1 booster Coup d'envoi offert ; le 7e jour d'affilée, 1 booster Prolongation
--   (au moins une Élite garantie). Un jour manqué : la série repart du jour 1.
-- Défis de la semaine : deux nouveaux (3 victoires en classé, une équipe de Ligue 1) qui donnent aussi un booster.
-- Albums : des listes de cartes à réunir ; un album complet se réclame une fois (ballons, boosters et/ou une carte exclusive).

-- ============ 1. Pack du jour ============
create or replace function public._streak_pack(d int) returns text language sql immutable as $$
  select case when d >= 7 then 'prolongation' else 'coup-envoi' end
$$;

create or replace function public.streak_claim() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._need_account(); today date := (now() at time zone 'Europe/Paris')::date; st record; nd int; pk text;
begin
  insert into login_streak (user_id) values (uid) on conflict do nothing;
  select * into st from login_streak where user_id = uid for update;
  if st.last_claim = today then raise exception 'Pack du jour déjà récupéré, reviens demain'; end if;
  -- un jour manqué : la série repart du jour 1
  nd := case when st.last_claim is null or today - st.last_claim > 1 then 1 else st.day % 7 + 1 end;
  pk := public._streak_pack(nd);
  update login_streak set day = nd, last_claim = today, total = total + 1 where user_id = uid;
  perform public._gift(uid, pk, 1);
  return jsonb_build_object('day', nd, 'booster', pk, 'reward', 0,
    'balloons', (select balloons from profiles where id = uid));
end $$;

-- ============ 2. Défis de la semaine ============
create or replace function public._mission_defs()
returns table (id text, period text, title text, metric text, target int, reward int)
language sql immutable as $$
  select * from (values
    ('d_open3',  'day',  'Ouvre 3 boosters',                    'openings',     3,  30),
    ('d_elite',  'day',  'Obtiens une carte Élite ou mieux',    'best_elite',   1,  40),
    ('d_market', 'day',  'Fais un achat ou une vente au marché','market',       1,  60),
    ('w_open20', 'week', 'Ouvre 20 boosters',                   'openings',    20, 200),
    ('w_leg',    'week', 'Obtiens une Légende ou mieux',        'best_legende', 1, 250),
    ('w_trade',  'week', 'Réussis un échange avec un ami',      'trades',       1, 300),
    ('w_rk3',    'week', 'Gagne 3 matchs classés',              'ranked_wins',  3, 150),
    ('w_l1',     'week', 'Complète une équipe de Ligue 1', 'l1_cards', 11, 200)
  ) v(id, period, title, metric, target, reward)
$$;

-- booster offert en plus des ballons (null = ballons seulement)
create or replace function public._mission_pack(p_id text) returns text language sql immutable as $$
  select case p_id when 'w_rk3' then 'prolongation' when 'w_l1' then 'prolongation' else null end
$$;

create or replace function public._metric(p_user uuid, p_m text, p_from timestamptz default null, p_to timestamptz default null)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare v bigint := 0; lo timestamptz := coalesce(p_from, '-infinity'); hi timestamptz := coalesce(p_to, 'infinity');
begin
  if p_m = 'openings' then
    select count(*) into v from openings where user_id = p_user and created_at >= lo and created_at < hi;
  elsif p_m = 'best_elite' then
    select count(*) into v from openings where user_id = p_user and created_at >= lo and created_at < hi
      and best_rarity in ('elite','legende','mythique','prime','promo','goat');
  elsif p_m = 'best_legende' then
    select count(*) into v from openings where user_id = p_user and created_at >= lo and created_at < hi
      and best_rarity in ('legende','mythique','prime','promo','goat');
  elsif p_m = 'trades' then
    select count(*) into v from trades where status = 'accepted' and (from_user = p_user or to_user = p_user)
      and updated_at >= lo and updated_at < hi;
  elsif p_m = 'sales' then
    select count(*) into v from market_listings where status = 'sold' and seller = p_user and sold_at >= lo and sold_at < hi;
  elsif p_m = 'purchases' then
    select count(*) into v from market_listings where status = 'sold' and buyer = p_user and sold_at >= lo and sold_at < hi;
  elsif p_m = 'market' then
    select count(*) into v from market_listings where status = 'sold' and (seller = p_user or buyer = p_user) and sold_at >= lo and sold_at < hi;
  elsif p_m = 'ranked_wins' then
    select count(*) into v from ranked_matches where user_id = p_user and status = 'done' and my_score > opp_score
      and created_at >= lo and created_at < hi;
  elsif p_m = 'l1_cards' then
    select count(*) into v from openings o cross join lateral unnest(o.card_ids) x(cid) join cards c on c.id = x.cid
      where o.user_id = p_user and o.created_at >= lo and o.created_at < hi and c.league = 'Ligue 1';
  elsif p_m = 'cards_unique' then
    select count(*) into v from user_cards where user_id = p_user and quantity > 0;
  elsif p_m = 'own_legende' then
    select count(*) into v from user_cards uc join cards c on c.id = uc.card_id
      where uc.user_id = p_user and uc.quantity > 0 and c.rarity in ('legende','mythique','prime','promo','goat');
  elsif p_m = 'own_mythique' then
    select count(*) into v from user_cards uc join cards c on c.id = uc.card_id
      where uc.user_id = p_user and uc.quantity > 0 and c.rarity in ('mythique','prime','promo','goat');
  elsif p_m = 'own_prime' then
    select count(*) into v from user_cards uc join cards c on c.id = uc.card_id
      where uc.user_id = p_user and uc.quantity > 0 and c.rarity in ('prime','promo','goat');
  elsif p_m = 'own_goat' then
    select count(*) into v from user_cards uc join cards c on c.id = uc.card_id
      where uc.user_id = p_user and uc.quantity > 0 and c.rarity = 'goat';
  elsif p_m = 'level' then
    v := public.level_of(public.user_score(p_user));
  elsif p_m = 'friends' then
    select count(*) into v from friendships where status = 'accepted' and (requester = p_user or addressee = p_user);
  elsif p_m = 'login_days' then
    select coalesce(max(total), 0) into v from login_streak where user_id = p_user;
  end if;
  return coalesce(v, 0);
end $$;

create or replace function public._claim_one(p_user uuid, p_id text) returns int
language plpgsql security definer set search_path = public as $$
declare d record; lo timestamptz; hi timestamptz; n int; ds timestamptz; de timestamptz; ws timestamptz; we timestamptz; pk text;
begin
  select * into d from (
    select m.id, m.period, m.metric, m.target, m.reward, 'm'::text as k from public._mission_defs() m
    union all
    select a.id, 'all'::text, a.metric, a.target, a.reward, 'a'::text from public._ach_defs() a) x where x.id = p_id;
  if not found then return 0; end if;
  select b.ds, b.de into ds, de from public._day_bounds() b;
  select b.ws, b.we into ws, we from public._week_bounds(0) b;
  if d.period = 'day' then lo := ds; hi := de;
  elsif d.period = 'week' then lo := ws; hi := we; end if;
  if public._metric(p_user, d.metric, lo, hi) < d.target then return 0; end if;
  if d.k = 'm' then
    insert into mission_claims (user_id, mission_id, period_start) values (p_user, d.id, lo) on conflict do nothing;
  else
    insert into ach_claims (user_id, ach_id) values (p_user, d.id) on conflict do nothing;
  end if;
  get diagnostics n = row_count;
  if n = 0 then return 0; end if;
  update profiles set balloons = balloons + d.reward where id = p_user;
  if d.k = 'm' then
    pk := public._mission_pack(d.id);
    if pk is not null then perform public._gift(p_user, pk, 1); end if;
  end if;
  return d.reward;
end $$;

create or replace function public.missions_get() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._need_account(); ds timestamptz; de timestamptz; ws timestamptz; we timestamptz;
        today date := (now() at time zone 'Europe/Paris')::date; st record; claimed_days int := 0; nxt int := 1; can boolean := true;
        miss jsonb; ach jsonb; claimable int := 0;
begin
  select b.ds, b.de into ds, de from public._day_bounds() b;
  select b.ws, b.we into ws, we from public._week_bounds(0) b;
  select * into st from login_streak where user_id = uid;
  if found and st.last_claim is not null then
    can := st.last_claim <> today;
    -- série encore vivante si le dernier pack date d'aujourd'hui ou d'hier
    if today - st.last_claim <= 1 then claimed_days := st.day; nxt := st.day % 7 + 1; else claimed_days := 0; nxt := 1; end if;
    if not can then nxt := st.day % 7 + 1; end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'period', t.period, 'title', t.title, 'target', t.target, 'reward', t.reward,
           'pack', public._mission_pack(t.id), 'progress', least(t.p, t.target), 'claimed', t.c) order by t.period, t.reward), '[]'::jsonb),
         count(*) filter (where t.p >= t.target and not t.c)
    into miss, claimable
  from (select m.*, public._metric(uid, m.metric, case m.period when 'day' then ds else ws end, case m.period when 'day' then de else we end) as p,
               exists (select 1 from mission_claims c where c.user_id = uid and c.mission_id = m.id and c.period_start = case m.period when 'day' then ds else ws end) as c
        from public._mission_defs() m) t;
  with a as (
    select x.*, public._metric(uid, x.metric) as p, exists (select 1 from ach_claims c where c.user_id = uid and c.ach_id = x.id) as c
    from public._ach_defs() x)
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'descr', a.descr, 'target', a.target, 'reward', a.reward,
           'progress', least(a.p, a.target), 'claimed', a.c) order by a.c, (a.p >= a.target) desc, a.reward), '[]'::jsonb),
         claimable + count(*) filter (where a.p >= a.target and not a.c)
    into ach, claimable from a;
  return jsonb_build_object(
    'balloons', (select balloons from profiles where id = uid),
    'streak', jsonb_build_object('claimed', claimed_days, 'next', nxt, 'can_claim', can, 'total', coalesce(st.total, 0),
              'rewards', jsonb_build_array(0,0,0,0,0,0,0),
              'packs', (select jsonb_agg(public._streak_pack(i) order by i) from generate_series(1, 7) i)),
    'missions', miss, 'ach', ach, 'claimable', claimable,
    'day_end', de, 'week_end', we);
end $$;

-- ============ 3. Albums ============
create table if not exists public.albums (
  id              text primary key,
  title           text not null,
  descr           text,
  card_ids        int[] not null,
  reward_balloons int  not null default 0,
  reward_booster  text references public.boosters(id),
  reward_qty      int  not null default 1,
  reward_card     int  references public.cards(id),   -- carte exclusive offerte (mets-la inactive pour qu'elle ne sorte pas des boosters)
  sort            int  not null default 0,
  active          boolean not null default true
);
create table if not exists public.album_claims (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  album_id   text not null references public.albums(id) on delete cascade,
  claimed_at timestamptz not null default now(),
  primary key (user_id, album_id)
);
alter table public.albums       enable row level security;
alter table public.album_claims enable row level security;
drop policy if exists "albums visibles" on public.albums;
create policy "albums visibles" on public.albums for select using (active);
drop policy if exists "mes albums" on public.album_claims;
create policy "mes albums" on public.album_claims for select using (user_id = auth.uid());
grant select on public.albums to anon, authenticated;
grant select on public.album_claims to authenticated;

create or replace function public.album_claim(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._need_account(); a albums%rowtype; miss int; n int; nb int;
begin
  select * into a from albums where id = p_id and active;
  if not found then raise exception 'Album introuvable'; end if;
  select count(*) into miss from unnest(a.card_ids) x(cid)
    where not exists (select 1 from user_cards uc where uc.user_id = uid and uc.card_id = x.cid and uc.quantity > 0);
  if miss > 0 then raise exception 'Il te manque encore % carte%', miss, case when miss > 1 then 's' else '' end; end if;
  insert into album_claims (user_id, album_id) values (uid, a.id) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Album déjà complété'; end if;
  update profiles set balloons = balloons + a.reward_balloons where id = uid returning balloons into nb;
  if a.reward_booster is not null then perform public._gift(uid, a.reward_booster, greatest(a.reward_qty, 1)); end if;
  if a.reward_card is not null then
    insert into user_cards (user_id, card_id) values (uid, a.reward_card)
    on conflict (user_id, card_id) do update set quantity = user_cards.quantity + 1;
  end if;
  perform public._notify(uid, 'album', 'Album complété', a.title || ' : ta récompense est arrivée.', 'albums');
  return jsonb_build_object('balloons', nb, 'reward_balloons', a.reward_balloons, 'booster', a.reward_booster,
    'qty', a.reward_qty, 'card', a.reward_card);
end $$;

-- les albums de départ (les numéros sont ceux des cartes dans la table cards)
insert into public.albums (id, title, descr, card_ids, reward_balloons, reward_booster, reward_qty, sort) values
  ('nouvelle-vague', 'La nouvelle vague',        'Les jeunes qui vont tout casser',            array[414,308,381,380,322,430,166,397,313], 500, 'prolongation', 1, 10),
  ('bdo-90',         'Ballons d’Or · années 90', 'Un lauréat par année, de 1990 à 1999',       array[58,258,24,56,100,99,256,13,15,71],       3000, 'pantheon',     1, 20),
  ('bdo-2000',       'Ballons d’Or · années 2000','Les lauréats de 2000 à 2009',               array[72,103,14,69,19,84,48,1,53],             3000, 'pantheon',     1, 30),
  ('france-98',      'France 98',                'Les champions du monde',                      array[15,123,296,297,292,298,107,352,367],     1500, 'prolongation', 2, 40),
  ('psg-qatar',      'PSG 2017',                 'Neymar, Mbappé, Cavani et la bande',         array[3,66,151,376,377,148],           2000, 'prolongation', 2, 50),
  ('barca-2009',     'Barça 2009',               'Le sextuplé de Guardiola',                    array[53,140,142,30,29,132,133,284],      3000, 'pantheon',     1, 60),
  ('manu-2008',      'Manchester United 2008',   'Les champions d’Europe de Ferguson',         array[1,289,129,130,345,343,344,79],           2000, 'prolongation', 2, 70),
  ('arsenal-wenger', 'L’Arsenal de Wenger',      'Les Invincibles et leurs aînés',              array[25,107,97,352,351,350,283,400],          1500, 'prolongation', 2, 80)
on conflict (id) do update set title = excluded.title, descr = excluded.descr, card_ids = excluded.card_ids,
  reward_balloons = excluded.reward_balloons, reward_booster = excluded.reward_booster, reward_qty = excluded.reward_qty, sort = excluded.sort;

-- ============ 4. Droits ============
revoke all on function public._streak_pack(int), public._mission_pack(text) from public, anon, authenticated;
revoke all on function public._metric(uuid,text,timestamptz,timestamptz), public._claim_one(uuid,text) from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['streak_claim()', 'missions_get()', 'album_claim(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
