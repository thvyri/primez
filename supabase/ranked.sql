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
        select p.username, rp.elo, rp.wins, rp.draws, rp.losses, rp.user_id=auth.uid() as me
        from ranked_players rp join profiles p on p.id=rp.user_id
        where (rp.wins+rp.draws+rp.losses)>0 order by rp.elo desc, rp.wins desc limit 10) t),'[]'::jsonb),
    'recent',coalesce((select jsonb_agg(m order by m.created_at desc) from (
        select opp_name, opp_elo, my_score, opp_score, elo_after-elo_before as delta, reward, created_at
        from ranked_matches where user_id=auth.uid() order by created_at desc limit 8) m),'[]'::jsonb)
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

-- 5) jouer un match classé : adversaire = onze d'un autre joueur proche en Elo (sinon une IA à ton niveau)
create or replace function public.ranked_play()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  me public.ranked_players; opp record; v_opp_cards int[]; v_opp_name text; v_opp_elo int; v_opp_user uuid;
  pa numeric; pb numeric; la numeric; lb numeric; ga int:=0; gb int:=0; i int; t numeric; m int;
  ev jsonb:='[]'; s numeric; expct numeric; delta int; v_new int; v_reward int:=0; v_tier int; v_mid bigint; sc int; mins int[];
  bots text[]:=array['Racing Pixel','AS Algorithme','Olympique Binaire','FC Neurone','Sporting Silicium','Dynamo Data','Real Robot','Inter Circuit','Atlético Code','Union Cyber'];
begin
  me := rk_me();
  if coalesce(array_length(me.cards,1),0)<>11 then raise exception 'Compose ton onze avant de jouer'; end if;
  if (select count(*) from user_cards where user_id=auth.uid() and card_id=any(me.cards) and quantity>0)<>11 then
    raise exception 'Une carte de ton onze n''est plus dans ta collection : modifie ton équipe'; end if;
  if me.today>=60 then raise exception 'Limite de 60 matchs classés par jour atteinte, reviens demain'; end if;

  -- adversaire réel : Elo proche (fenêtre qui s'élargit), pas soi-même, pas le même deux fois de suite
  for i in 1..4 loop
    select rp.user_id, rp.elo, rp.cards, p.username into opp
    from ranked_players rp join profiles p on p.id=rp.user_id
    where rp.user_id<>auth.uid() and array_length(rp.cards,1)=11 and abs(rp.elo-me.elo)<=100*i*i
      and rp.user_id is distinct from (select opp_user from ranked_matches where user_id=auth.uid() order by created_at desc limit 1)
    order by random() limit 1;
    exit when opp.user_id is not null;
  end loop;

  if opp.user_id is not null then
    v_opp_user:=opp.user_id; v_opp_elo:=opp.elo; v_opp_cards:=opp.cards; v_opp_name:=coalesce(opp.username,'Joueur');
  else
    -- IA : 11 cartes tirées autour du niveau de ton équipe
    v_opp_user:=null; v_opp_elo:=greatest(600, me.elo + (floor(random()*121)-60)::int); v_opp_name:=bots[1+floor(random()*array_length(bots,1))::int];
    pa := rk_team_power(me.cards);
    select array_agg(id) into v_opp_cards from (
      select id from cards where coalesce(active,true) and rk_card_rating(rarity,name) between pa-6 and pa+5 order by random() limit 11) z;
    if coalesce(array_length(v_opp_cards,1),0)<11 then
      select array_agg(id) into v_opp_cards from (select id from cards order by abs(rk_card_rating(rarity,name)-pa), random() limit 11) z;
    end if;
  end if;

  -- simulation : chaque équipe a ~10 occasions, la qualité dépend de l'écart de force
  pa := rk_team_power(me.cards); pb := rk_team_power(v_opp_cards);
  la := 1.35*exp((pa-pb)/14.0); lb := 1.35*exp((pb-pa)/14.0);
  for m in 1..90 loop
    if random() < la/90 then
      ga:=ga+1; sc := me.cards[1+ (case when random()<.75 then 6+floor(random()*5)::int else 1+floor(random()*5)::int end)];
      ev := ev || jsonb_build_object('m',m,'side','me','card',sc);
    elsif random() < lb/90 then
      gb:=gb+1; sc := v_opp_cards[1+ (case when random()<.75 then 6+floor(random()*5)::int else 1+floor(random()*5)::int end)];
      ev := ev || jsonb_build_object('m',m,'side','opp','card',sc);
    end if;
  end loop;

  -- Elo (K=32, seul ton Elo bouge : l'adversaire n'est pas présent)
  s := case when ga>gb then 1 when ga=gb then 0.5 else 0 end;
  expct := 1/(1+power(10,(v_opp_elo-me.elo)/400.0));
  delta := round(32*(s-expct));
  if s=1 and delta<6 then delta:=6; end if;
  if s=0 and delta>-4 then delta:=-4; end if;
  v_new := greatest(0, me.elo+delta);

  -- ballons : c'est le mode principal pour en gagner
  v_tier := rk_tier(me.elo);
  if me.today < 40 then
    v_reward := case when s=1 then 150+40*v_tier when s=0.5 then 60+15*v_tier else 25 end;
    if s=1 then v_reward := v_reward + least(me.streak,5)*20; end if;
    if s=1 and not me.won_today then v_reward := v_reward + 500; end if;   -- première victoire du jour
  end if;

  update ranked_players set
    elo=v_new, best_elo=greatest(best_elo,v_new),
    wins=wins+(s=1)::int, draws=draws+(s=0.5)::int, losses=losses+(s=0)::int,
    streak=case when s=1 then streak+1 else 0 end,
    today=today+1, won_today=won_today or s=1, updated_at=now()
  where user_id=auth.uid();
  if v_reward>0 then update profiles set balloons=balloons+v_reward where id=auth.uid(); end if;

  insert into ranked_matches(user_id,opp_user,opp_name,opp_elo,opp_cards,my_cards,my_score,opp_score,events,elo_before,elo_after,reward)
  values (auth.uid(),v_opp_user,v_opp_name,v_opp_elo,v_opp_cards,me.cards,ga,gb,ev,me.elo,v_new,v_reward) returning id into v_mid;

  return jsonb_build_object('id',v_mid,'opp_name',v_opp_name,'opp_elo',v_opp_elo,'opp_cards',to_jsonb(v_opp_cards),'bot',v_opp_user is null,
    'my_power',round(pa,1),'opp_power',round(pb,1),'my_score',ga,'opp_score',gb,'events',ev,
    'elo_before',me.elo,'elo_after',v_new,'delta',v_new-me.elo,'reward',v_reward,
    'balloons',(select balloons from profiles where id=auth.uid()),'streak',case when s=1 then me.streak+1 else 0 end,'today',me.today+1);
end $$;

grant execute on function public.ranked_state() to authenticated;
grant execute on function public.ranked_save_team(text,int[]) to authenticated;
grant execute on function public.ranked_play() to authenticated;
revoke execute on function public.rk_me() from anon, authenticated, public;
