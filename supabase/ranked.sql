-- =====================================================================
--  PrimeZ · Mode CLASSÉ (11 contre 11, Elo, rangs, top 10)
--  À exécuter une fois dans Supabase : SQL Editor → New query → coller → Run.
--  Le match est calculé ici, côté serveur : le navigateur ne fait que l'afficher,
--  donc impossible de tricher sur le score, l'Elo ou les ballons gagnés.
-- =====================================================================

-- 0) vérification : les tables et colonnes utilisées existent bien
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='user_cards' and column_name='user_id')
  or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='user_cards' and column_name='card_id')
  or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='user_cards' and column_name='quantity') then
    raise exception 'PrimeZ ranked : la table user_cards doit avoir les colonnes user_id, card_id, quantity';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='balloons')
  or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='username') then
    raise exception 'PrimeZ ranked : la table profiles doit avoir les colonnes balloons et username';
  end if;
end $$;

-- 1) tables
create table if not exists public.ranked_players (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  elo         int  not null default 900,
  best_elo    int  not null default 900,
  wins        int  not null default 0,
  draws       int  not null default 0,
  losses      int  not null default 0,
  streak      int  not null default 0,      -- victoires d'affilée
  day         date not null default current_date,
  today       int  not null default 0,      -- matchs joués aujourd'hui
  won_today   boolean not null default false,
  formation   text not null default '4-3-3',
  cards       int[] not null default '{}',  -- 11 cartes, index 0 = gardien
  updated_at  timestamptz not null default now()
);

create table if not exists public.ranked_matches (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  opp_user    uuid,
  opp_name    text not null,
  opp_elo     int  not null,
  opp_cards   int[] not null,
  my_cards    int[] not null,
  my_score    int  not null,
  opp_score   int  not null,
  events      jsonb not null default '[]',
  elo_before  int  not null,
  elo_after   int  not null,
  reward      int  not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists ranked_matches_user_idx on public.ranked_matches(user_id, created_at desc);
create index if not exists ranked_players_elo_idx on public.ranked_players(elo desc);

-- tout passe par les fonctions ci-dessous (security definer) : aucun accès direct aux tables
alter table public.ranked_players enable row level security;
alter table public.ranked_matches enable row level security;
revoke all on public.ranked_players from anon, authenticated;
revoke all on public.ranked_matches from anon, authenticated;

-- 2) note d'une carte (même échelle que l'affichage du site : Commune ~70 … GOAT ~96)
create or replace function public.rk_card_rating(p_rarity text, p_name text)
returns int language sql immutable as $$
  select case
    when p_rarity='promo' and p_name ilike 'L.YAMAL%' then 94
    else coalesce((jsonb_build_object('commune',70,'rare',74,'elite',78,'legende',82,'mythique',86,'promo',84,'prime',91,'goat',96)->>p_rarity)::int, 70)
  end;
$$;

-- force d'une équipe : moyenne des notes + cohésion (joueurs du même club / du même championnat)
create or replace function public.rk_team_power(p_cards int[])
returns numeric language sql stable as $$
  with c as (select id, rarity, name, club, league from public.cards where id = any(p_cards)),
  r as (select avg(public.rk_card_rating(rarity, name))::numeric as avg_r from c),
  coh as (
    select coalesce(sum(least(n-1,3)),0)::numeric as club_pts from (select count(*) n from c where club is not null and club<>'' group by club) x
  ),
  lea as (
    select coalesce(sum(least(n-2,3)),0)::numeric as lea_pts from (select count(*) n from c where league is not null and league not in ('','Autres') group by league having count(*)>=3) y
  )
  select r.avg_r + least(coh.club_pts*0.35 + lea.lea_pts*0.2, 4) from r, coh, lea;
$$;

create or replace function public.rk_cohesion(p_cards int[])
returns int language sql stable as $$
  select round(least(
    (select coalesce(sum(least(n-1,3)),0) from (select count(*) n from public.cards where id=any(p_cards) and club is not null and club<>'' group by club) x)*0.35
  + (select coalesce(sum(least(n-2,3)),0) from (select count(*) n from public.cards where id=any(p_cards) and league is not null and league not in ('','Autres') group by league having count(*)>=3) y)*0.2
  , 4) * 25)::int;   -- 0 à 100
$$;

-- rang (index 0..6 : Remplaçant, Titulaire, International, Capitaine, Historique, Prime, GOAT)
create or replace function public.rk_tier(p_elo int)
returns int language sql immutable as $$
  select case when p_elo>=2100 then 6 when p_elo>=1800 then 5 when p_elo>=1550 then 4
              when p_elo>=1300 then 3 when p_elo>=1100 then 2 when p_elo>=950 then 1 else 0 end;
$$;

-- ligne du joueur (créée au besoin, compteur du jour remis à zéro)
create or replace function public.rk_me()
returns public.ranked_players language plpgsql security definer set search_path=public as $$
declare me public.ranked_players;
begin
  if auth.uid() is null then raise exception 'Connecte-toi pour jouer en classé'; end if;
  insert into ranked_players(user_id) values (auth.uid()) on conflict (user_id) do nothing;
  update ranked_players set day=current_date, today=0, won_today=false where user_id=auth.uid() and day<>current_date;
  select * into me from ranked_players where user_id=auth.uid();
  return me;
end $$;

-- 3) état : mon rang, mon équipe, top 10, mes derniers matchs
create or replace function public.ranked_state()
returns jsonb language plpgsql security definer set search_path=public as $$
declare me public.ranked_players; v_rank int; v_total int;
begin
  me := rk_me();
  select count(*)+1 into v_rank from ranked_players where elo>me.elo and (wins+draws+losses)>0;
  select count(*) into v_total from ranked_players where (wins+draws+losses)>0;
  return jsonb_build_object(
    'elo',me.elo,'best',me.best_elo,'wins',me.wins,'draws',me.draws,'losses',me.losses,'streak',me.streak,
    'today',me.today,'won_today',me.won_today,'formation',me.formation,'cards',to_jsonb(me.cards),
    'rank',v_rank,'players',v_total,'cohesion',case when array_length(me.cards,1)=11 then rk_cohesion(me.cards) else 0 end,
    'top',coalesce((select jsonb_agg(t order by t.elo desc) from (
        select p.username, to_jsonb(p)->>'avatar_url' as avatar, rp.elo, rp.wins, rp.draws, rp.losses, rp.user_id=auth.uid() as me
        from ranked_players rp join profiles p on p.id=rp.user_id
        where (rp.wins+rp.draws+rp.losses)>0 order by rp.elo desc, rp.wins desc limit 50) t),'[]'::jsonb),
    'recent',coalesce((select jsonb_agg(m order by m.created_at desc) from (
        select opp_name, opp_elo, my_score, opp_score, elo_after-elo_before as delta, reward, created_at
        from ranked_matches where user_id=auth.uid() and status='done' order by created_at desc limit 8) m),'[]'::jsonb)
  );
end $$;

-- 4) enregistrer son onze (11 cartes différentes, toutes possédées)
create or replace function public.ranked_save_team(p_form text, p_cards int[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare n int;
begin
  perform rk_me();
  if p_form not in ('4-3-3','4-4-2','4-2-3-1','3-5-2','3-4-3','5-3-2','4-1-2-1-2') then raise exception 'Formation inconnue'; end if;
  if coalesce(array_length(p_cards,1),0)<>11 then raise exception 'Il faut 11 joueurs'; end if;
  if (select count(distinct x) from unnest(p_cards) x)<>11 then raise exception 'Un joueur ne peut pas jouer deux fois'; end if;
  select count(*) into n from user_cards where user_id=auth.uid() and card_id=any(p_cards) and quantity>0;
  if n<>11 then raise exception 'Tu dois posséder les 11 cartes'; end if;
  update ranked_players set formation=p_form, cards=p_cards, updated_at=now() where user_id=auth.uid();
  return jsonb_build_object('ok',true,'cohesion',rk_cohesion(p_cards));
end $$;

-- 5) MATCH INTERACTIF : 8 temps forts. En attaque tu choisis Frapper / Dribbler / Passer ; en défense tu lis l'action adverse.
--    Le choix caché de l'adversaire est tiré ici et n'est jamais envoyé avant que tu aies joué : impossible de tricher.
alter table public.ranked_matches add column if not exists status text not null default 'done';
alter table public.ranked_matches add column if not exists step int not null default 0;
alter table public.ranked_matches add column if not exists moments jsonb not null default '[]';
alter table public.ranked_matches add column if not exists my_power numeric;
alter table public.ranked_matches add column if not exists opp_power numeric;
drop function if exists public.ranked_play();

-- vue publique d'un match en cours (sans les choix cachés)
create or replace function public.rk_public(p public.ranked_matches)
returns jsonb language sql stable as $$
  select jsonb_build_object('id',p.id,'opp_name',p.opp_name,'opp_elo',p.opp_elo,'opp_cards',to_jsonb(p.opp_cards),'my_cards',to_jsonb(p.my_cards),'bot',p.opp_user is null,
    'my_power',round(p.my_power,1),'opp_power',round(p.opp_power,1),'my_score',p.my_score,'opp_score',p.opp_score,'step',p.step,'status',p.status,
    'events',p.events,'elo_before',p.elo_before,
    'moments',(select coalesce(jsonb_agg(m - 'hid' order by o),'[]'::jsonb) from jsonb_array_elements(p.moments) with ordinality as t(m,o)));
$$;

-- fin de match : Elo, série, ballons (forfait = défaite)
create or replace function public.rk_finalize(p_id bigint, p_forfeit boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare mt public.ranked_matches; me public.ranked_players; s numeric; expct numeric; delta int; v_new int; v_reward int:=0; v_tier int;
begin
  select * into mt from ranked_matches where id=p_id and status='live' for update; if not found then return null; end if;
  select * into me from ranked_players where user_id=mt.user_id for update;
  s := case when p_forfeit then 0 when mt.my_score>mt.opp_score then 1 when mt.my_score=mt.opp_score then 0.5 else 0 end;
  expct := 1/(1+power(10,(mt.opp_elo-me.elo)/400.0)); delta := round(32*(s-expct));
  if s=1 and delta<6 then delta:=6; end if; if s=0 and delta>-4 then delta:=-4; end if;
  v_new := greatest(0, me.elo+delta); v_tier := rk_tier(me.elo);
  if me.today < 40 and not p_forfeit then
    v_reward := case when s=1 then 150+40*v_tier when s=0.5 then 60+15*v_tier else 25 end;
    if s=1 then v_reward := v_reward + least(me.streak,5)*20; end if;
    if s=1 and not me.won_today then v_reward := v_reward + 500; end if;
  end if;
  update ranked_players set elo=v_new, best_elo=greatest(best_elo,v_new), wins=wins+(s=1)::int, draws=draws+(s=0.5)::int, losses=losses+(s=0)::int,
    streak=case when s=1 then streak+1 else 0 end, today=today+1, won_today=won_today or s=1, updated_at=now() where user_id=mt.user_id;
  if v_reward>0 then update profiles set balloons=balloons+v_reward where id=mt.user_id; end if;
  update ranked_matches set status='done', elo_before=me.elo, elo_after=v_new, reward=v_reward where id=p_id;
  return jsonb_build_object('elo_before',me.elo,'elo_after',v_new,'delta',v_new-me.elo,'reward',v_reward,'forfeit',p_forfeit,
    'balloons',(select balloons from profiles where id=mt.user_id),'streak',case when s=1 then me.streak+1 else 0 end);
end $$;

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

  for i in 1..4 loop
    select rp.user_id, rp.elo, rp.cards, p.username into opp from ranked_players rp join profiles p on p.id=rp.user_id
    where rp.user_id<>auth.uid() and array_length(rp.cards,1)=11 and abs(rp.elo-me.elo)<=100*i*i
      and rp.user_id is distinct from (select opp_user from ranked_matches where user_id=auth.uid() order by created_at desc limit 1)
    order by random() limit 1;
    exit when opp.user_id is not null;
  end loop;
  pa := rk_team_power(me.cards);
  if opp.user_id is not null then
    v_opp_user:=opp.user_id; v_opp_elo:=opp.elo; v_opp_cards:=opp.cards; v_opp_name:=coalesce(opp.username,'Joueur');
  else
    v_opp_user:=null; v_opp_elo:=greatest(600, me.elo + (floor(random()*121)-60)::int); v_opp_name:=bots[1+floor(random()*array_length(bots,1))::int];
    select array_agg(id) into v_opp_cards from (select id from cards where coalesce(active,true) and rk_card_rating(rarity,name) between pa-6 and pa+5 order by random() limit 11) z;
    if coalesce(array_length(v_opp_cards,1),0)<11 then
      select array_agg(id) into v_opp_cards from (select id from cards order by abs(rk_card_rating(rarity,name)-pa), random() limit 11) z;
    end if;
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

-- jouer un temps fort : p_choice = F (frappe), D (dribble), P (passe). En défense, c'est l'action adverse que tu anticipes.
create or replace function public.ranked_move(p_match bigint, p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare mt public.ranked_matches; mo jsonb; side text; hid text; diff numeric; p numeric; goal boolean; fin jsonb; n int;
begin
  if p_choice not in ('F','D','P') then raise exception 'Action inconnue'; end if;
  select * into mt from ranked_matches where id=p_match and user_id=auth.uid() and status='live' for update;
  if not found then raise exception 'Match introuvable ou terminé'; end if;
  n := jsonb_array_length(mt.moments); mo := mt.moments->mt.step; side := mo->>'side'; hid := mo->>'hid';
  diff := greatest(-0.15, least(0.15, (mt.my_power-mt.opp_power)/40.0));
  if side='att' then p := case when p_choice=hid then 0.16 else 0.6 end + diff;   -- le défenseur a lu ton action : presque impossible
  else              p := case when p_choice=hid then 0.12 else 0.52 end - diff;   -- tu as lu l'attaque adverse : il ne marque quasi jamais
  end if;
  goal := random() < greatest(0.05, least(0.9, p));
  update ranked_matches set
    my_score = my_score + (side='att' and goal)::int, opp_score = opp_score + (side='def' and goal)::int, step = step+1,
    events = events || jsonb_build_object('m',mo->'m','side',case when side='att' then 'me' else 'opp' end,'card',mo->'actor','goal',goal,'choice',p_choice,'hid',hid)
  where id=p_match returning * into mt;
  if mt.step >= n then fin := rk_finalize(p_match); end if;
  return jsonb_build_object('step',mt.step,'side',side,'choice',p_choice,'hid',hid,'goal',goal,'my_score',mt.my_score,'opp_score',mt.opp_score,'done',mt.step>=n,'final',fin);
end $$;

-- abandon volontaire (bouton « Abandonner ») : défaite
create or replace function public.ranked_forfeit(p_match bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from ranked_matches where id=p_match and user_id=auth.uid() and status='live') then return null; end if;
  return rk_finalize(p_match,true);
end $$;

-- le match en cours éventuel (pour reprendre après un rechargement)
create or replace function public.ranked_live()
returns jsonb language sql stable security definer set search_path=public as $$
  select rk_public(m) from ranked_matches m where user_id=auth.uid() and status='live' order by created_at desc limit 1;
$$;

grant execute on function public.ranked_state() to authenticated;
grant execute on function public.ranked_save_team(text,int[]) to authenticated;
grant execute on function public.ranked_start() to authenticated;
grant execute on function public.ranked_move(bigint,text) to authenticated;
grant execute on function public.ranked_forfeit(bigint) to authenticated;
grant execute on function public.ranked_live() to authenticated;
revoke execute on function public.rk_me() from anon, authenticated, public;
revoke execute on function public.rk_finalize(bigint,boolean) from anon, authenticated, public;
