-- ============================================================================
--  PrimeZ · CLASSÉ EN DIRECT : uniquement contre de vrais joueurs
--  À lancer une fois dans Supabase > SQL Editor, APRÈS ranked.sql. Relançable sans risque.
--
--  « Jouer un match classé » met le joueur dans une file d'attente, sans limite de temps.
--  Dès qu'un autre joueur cherche aussi, un duel partagé est créé (niveau proche d'abord,
--  la recherche s'élargit avec l'attente). Pas de club IA.
--  Un joueur absent plus de 30 secondes pendant le duel perd par forfait.
--  Tout est calculé ici : impossible de voir le choix de l'adversaire avant la fin du tour.
-- ============================================================================

-- 0) ranked.sql doit avoir été lancé
do $$
begin
  if to_regclass('public.ranked_players') is null or to_regclass('public.ranked_matches') is null then
    raise exception 'PrimeZ classé en direct : lance d''abord ranked.sql';
  end if;
end $$;

-- 1) tables
create table if not exists public.ranked_queue (
  user_id   uuid primary key references public.profiles(id) on delete cascade,
  elo       int  not null,
  joined_at timestamptz not null default now(),
  beat      timestamptz not null default now()      -- dernier signe de vie (le site en envoie un toutes les 2 s)
);

create table if not exists public.ranked_duels (
  id         bigserial primary key,
  a          uuid not null references public.profiles(id) on delete cascade,
  b          uuid not null references public.profiles(id) on delete cascade,
  a_name     text not null, b_name text not null,
  a_elo      int  not null, b_elo  int  not null,
  a_cards    int[] not null, b_cards int[] not null,
  a_power    numeric not null, b_power numeric not null,
  a_score    int not null default 0, b_score int not null default 0,
  moments    jsonb not null,                 -- 8 temps forts : {m, att:'a'|'b', actor, foe}
  step       int  not null default 0,
  a_choice   text, b_choice text,            -- choix du tour en cours (jamais montré à l'autre avant la résolution)
  a_miss     int  not null default 0, b_miss int not null default 0,   -- tours manqués d'affilée
  deadline   timestamptz not null,
  events     jsonb not null default '[]',    -- {m, att, card, goal, ca (choix attaquant), cd (choix défenseur)}
  status     text not null default 'live',   -- live | done
  forfeit    text,                           -- 'a' ou 'b' si abandon / absence, 'x' si match annulé
  a_final    jsonb, b_final jsonb,
  created_at timestamptz not null default now()
);
-- dernier signe de vie de chaque joueur pendant le duel (absent plus de 30 s = forfait)
alter table public.ranked_duels add column if not exists a_seen timestamptz not null default now();
alter table public.ranked_duels add column if not exists b_seen timestamptz not null default now();
create index if not exists ranked_duels_a_idx on public.ranked_duels(a) where status='live';
create index if not exists ranked_duels_b_idx on public.ranked_duels(b) where status='live';

alter table public.ranked_queue enable row level security;
alter table public.ranked_duels enable row level security;
revoke all on public.ranked_queue from anon, authenticated;
revoke all on public.ranked_duels from anon, authenticated;

-- 2) le duel vu par un joueur : même forme que rk_public(), pour réutiliser l'écran de match
create or replace function public.rk_duel_view(d public.ranked_duels, p_uid uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'duel', true, 'id', d.id, 'bot', false, 'status', d.status, 'step', d.step,
    'opp_name', case when ia then d.b_name else d.a_name end,
    'opp_elo',  case when ia then d.b_elo  else d.a_elo  end,
    'elo_before', case when ia then d.a_elo else d.b_elo end,
    'my_cards',  to_jsonb(case when ia then d.a_cards else d.b_cards end),
    'opp_cards', to_jsonb(case when ia then d.b_cards else d.a_cards end),
    'my_power',  round(case when ia then d.a_power else d.b_power end, 1),
    'opp_power', round(case when ia then d.b_power else d.a_power end, 1),
    'my_score',  case when ia then d.a_score else d.b_score end,
    'opp_score', case when ia then d.b_score else d.a_score end,
    'i_chose',   (case when ia then d.a_choice else d.b_choice end) is not null,
    'opp_chose', (case when ia then d.b_choice else d.a_choice end) is not null,
    'opp_away',  greatest(0, floor(extract(epoch from (now() - case when ia then d.b_seen else d.a_seen end))))::int,
    'left', greatest(0, ceil(extract(epoch from (d.deadline - now()))))::int,
    'forfeit_by', case when d.forfeit is null then null when d.forfeit='x' then 'none' when (d.forfeit='a')=ia then 'me' else 'opp' end,
    'final', case when ia then d.a_final else d.b_final end,
    'moments', (select coalesce(jsonb_agg(jsonb_build_object('m', m->'m', 'actor', m->'actor', 'foe', m->'foe',
                  'side', case when ((m->>'att')='a')=ia then 'att' else 'def' end) order by o), '[]'::jsonb)
                from jsonb_array_elements(d.moments) with ordinality as t(m,o)),
    -- côté joueur : « choice » = mon choix, « hid » = celui de l'adversaire
    'events', (select coalesce(jsonb_agg(jsonb_build_object('m', e->'m', 'card', e->'card', 'goal', e->'goal',
                  'side',   case when ((e->>'att')='a')=ia then 'me' else 'opp' end,
                  'choice', case when ((e->>'att')='a')=ia then e->'ca' else e->'cd' end,
                  'hid',    case when ((e->>'att')='a')=ia then e->'cd' else e->'ca' end,
                  'auto',   case when ((e->>'att')='a')=ia then e->'da' else e->'aa' end) order by o), '[]'::jsonb)
                from jsonb_array_elements(d.events) with ordinality as t(e,o)))
  from (select d.a = p_uid as ia) x;
$$;

-- 3) fin du duel : Elo, série, ballons pour LES DEUX joueurs (mêmes règles que rk_finalize),
--    et une ligne dans ranked_matches pour chacun (historique, « derniers matchs »)
create or replace function public.rk_duel_finalize(p_id bigint, p_forfeit text default null)
returns void language plpgsql security definer set search_path=public as $$
declare d public.ranked_duels; pl record; me public.ranked_players; s numeric; expct numeric; delta int; v_new int; v_reward int; v_tier int;
        ia boolean; my_s int; op_s int; op_elo int; fin jsonb; ev jsonb; mo jsonb; ff boolean;
begin
  select * into d from ranked_duels where id=p_id and status='live' for update; if not found then return; end if;
  if p_forfeit is not null then    -- le score affiché doit donner tort à celui qui part
    if p_forfeit='a' then d.a_score := 0; d.b_score := greatest(d.b_score, 3); else d.b_score := 0; d.a_score := greatest(d.a_score, 3); end if;
  end if;
  for pl in select * from (values ('a'), ('b')) v(k) loop
    ia := pl.k='a'; ff := p_forfeit is not distinct from pl.k;
    my_s := case when ia then d.a_score else d.b_score end; op_s := case when ia then d.b_score else d.a_score end;
    op_elo := case when ia then d.b_elo else d.a_elo end;
    insert into ranked_players(user_id) values (case when ia then d.a else d.b end) on conflict (user_id) do nothing;
    update ranked_players set day=current_date, today=0, won_today=false where user_id=(case when ia then d.a else d.b end) and day<>current_date;
    select * into me from ranked_players where user_id=(case when ia then d.a else d.b end) for update;
    s := case when ff then 0 when my_s>op_s then 1 when my_s=op_s then 0.5 else 0 end;
    expct := 1/(1+power(10,(op_elo-me.elo)/400.0)); delta := round(32*(s-expct));
    if s=1 and delta<6 then delta:=6; end if; if s=0 and delta>-4 then delta:=-4; end if;
    v_new := greatest(0, me.elo+delta); v_tier := rk_tier(me.elo); v_reward := 0;
    if me.today < 40 and not ff then
      v_reward := case when s=1 then 150+40*v_tier when s=0.5 then 60+15*v_tier else 25 end;
      if s=1 then v_reward := v_reward + least(me.streak,5)*20; end if;
      if s=1 and not me.won_today then v_reward := v_reward + 500; end if;
    end if;
    update ranked_players set elo=v_new, best_elo=greatest(best_elo,v_new), wins=wins+(s=1)::int, draws=draws+(s=0.5)::int, losses=losses+(s=0)::int,
      streak=case when s=1 then streak+1 else 0 end, today=today+1, won_today=won_today or s=1, updated_at=now() where user_id=me.user_id;
    if v_reward>0 then update profiles set balloons=balloons+v_reward where id=me.user_id; end if;
    fin := jsonb_build_object('elo_before',me.elo,'elo_after',v_new,'delta',v_new-me.elo,'reward',v_reward,'forfeit',ff,
      'opp_forfeit', p_forfeit is not null and not ff,
      'balloons',(select balloons from profiles where id=me.user_id),'streak',case when s=1 then me.streak+1 else 0 end);
    if ia then d.a_final := fin; else d.b_final := fin; end if;
    select rk_duel_view(d, me.user_id)->'events', rk_duel_view(d, me.user_id)->'moments' into ev, mo;
    insert into ranked_matches(user_id,opp_user,opp_name,opp_elo,opp_cards,my_cards,my_score,opp_score,events,elo_before,elo_after,reward,status,step,moments,my_power,opp_power)
    values (me.user_id, case when ia then d.b else d.a end, case when ia then d.b_name else d.a_name end, op_elo,
      case when ia then d.b_cards else d.a_cards end, case when ia then d.a_cards else d.b_cards end, my_s, op_s, coalesce(ev,'[]'::jsonb),
      me.elo, v_new, v_reward, 'done', d.step, coalesce(mo,'[]'::jsonb), case when ia then d.a_power else d.b_power end, case when ia then d.b_power else d.a_power end);
  end loop;
  update ranked_duels set status='done', forfeit=p_forfeit, a_score=d.a_score, b_score=d.b_score, a_final=d.a_final, b_final=d.b_final,
    a_choice=null, b_choice=null where id=p_id;
end $$;

-- 4) faire avancer un duel : absence, tour expiré (choix au hasard pour celui qui n'a pas joué), puis résolution
create or replace function public.rk_duel_tick(p_id bigint)
returns void language plpgsql security definer set search_path=public as $$
declare d public.ranked_duels; mo jsonb; att text; ca text; cd text; diff numeric; p numeric; goal boolean; acts text[]:=array['F','D','P']; aa boolean:=false; da boolean:=false; n int;
begin
  select * into d from ranked_duels where id=p_id and status='live' for update; if not found then return; end if;
  -- les deux partis : match annulé, sans Elo ni ballons
  if d.a_seen < now() - interval '30 seconds' and d.b_seen < now() - interval '30 seconds' then
    update ranked_duels set status='done', forfeit='x', a_choice=null, b_choice=null where id=p_id; return;
  end if;
  -- absent plus de 30 secondes (page fermée, téléphone verrouillé…) : défaite par forfait
  if d.a_seen < now() - interval '30 seconds' then perform rk_duel_finalize(p_id,'a'); return; end if;
  if d.b_seen < now() - interval '30 seconds' then perform rk_duel_finalize(p_id,'b'); return; end if;
  if now() > d.deadline then
    if d.a_choice is null then d.a_choice := acts[1+floor(random()*3)::int]; d.a_miss := d.a_miss+1; if (d.moments->d.step->>'att')='a' then aa:=true; else da:=true; end if; end if;
    if d.b_choice is null then d.b_choice := acts[1+floor(random()*3)::int]; d.b_miss := d.b_miss+1; if (d.moments->d.step->>'att')='b' then aa:=true; else da:=true; end if; end if;
    update ranked_duels set a_choice=d.a_choice, b_choice=d.b_choice, a_miss=d.a_miss, b_miss=d.b_miss where id=p_id;
    -- deux tours sans jouer (30 s) : forfait aussi, même si la page est restée ouverte
    if d.a_miss>=2 then perform rk_duel_finalize(p_id,'a'); return; end if;
    if d.b_miss>=2 then perform rk_duel_finalize(p_id,'b'); return; end if;
  end if;
  if d.a_choice is null or d.b_choice is null then return; end if;
  n := jsonb_array_length(d.moments); mo := d.moments->d.step; att := mo->>'att';
  ca := case when att='a' then d.a_choice else d.b_choice end;   -- ce que tente l'attaquant
  cd := case when att='a' then d.b_choice else d.a_choice end;   -- ce que le défenseur a anticipé
  diff := greatest(-0.15, least(0.15, ((case when att='a' then d.a_power else d.b_power end) - (case when att='a' then d.b_power else d.a_power end))/40.0));
  p := case when ca=cd then 0.14 else 0.56 end + diff;           -- action lue par le défenseur : presque impossible de marquer
  goal := random() < greatest(0.05, least(0.9, p));
  update ranked_duels set
    a_score = a_score + (att='a' and goal)::int, b_score = b_score + (att='b' and goal)::int, step = step+1,
    events = events || jsonb_build_object('m',mo->'m','att',att,'card',mo->'actor','goal',goal,'ca',ca,'cd',cd,'aa',aa,'da',da),
    a_choice = null, b_choice = null,
    deadline = now() + interval '18 seconds'      -- 3 s pour voir l'action + 15 s pour choisir
  where id=p_id returning * into d;
  if d.step >= n then perform rk_duel_finalize(p_id, null); end if;
end $$;

-- un joueur donne signe de vie (chaque interrogation du site)
create or replace function public.rk_duel_seen(p_id bigint, p_uid uuid)
returns void language sql security definer set search_path=public as $$
  update ranked_duels set a_seen = case when a=p_uid then now() else a_seen end,
                          b_seen = case when b=p_uid then now() else b_seen end
  where id=p_id and status='live';
$$;

-- 5) apparier deux joueurs de la file (appelée sous verrou par join / poll)
create or replace function public.rk_duel_match(p_uid uuid)
returns bigint language plpgsql security definer set search_path=public as $$
declare me public.ranked_players; op public.ranked_players; q record; wait_s numeric; my_elo int; pa numeric; pb numeric; v_id bigint;
        i int; mins int[]; mom jsonb:='[]'; first text; att text; na text; nb text;
begin
  select extract(epoch from (now()-joined_at)), elo into wait_s, my_elo from ranked_queue where user_id=p_uid; if not found then return null; end if;
  -- niveau proche d'abord ; plus on attend, plus on élargit, jusqu'à accepter n'importe qui au bout de 30 s
  select rq.* into q from ranked_queue rq
   where rq.user_id<>p_uid and rq.beat > now() - interval '7 seconds'
     and (greatest(wait_s, extract(epoch from (now()-rq.joined_at))) >= 30
          or abs(rq.elo - my_elo) <= 150 + 30*greatest(wait_s, extract(epoch from (now()-rq.joined_at))))
   order by abs(rq.elo - my_elo), rq.joined_at limit 1;
  if not found then return null; end if;
  select * into me from ranked_players where user_id=p_uid; select * into op from ranked_players where user_id=q.user_id;
  if coalesce(array_length(me.cards,1),0)<>11 or coalesce(array_length(op.cards,1),0)<>11 then
    delete from ranked_queue where user_id in (p_uid,q.user_id) and user_id in (select user_id from ranked_players where coalesce(array_length(cards,1),0)<>11);
    return null;
  end if;
  pa := rk_team_power(me.cards); pb := rk_team_power(op.cards);
  select coalesce(username,'Joueur') into na from profiles where id=p_uid; select coalesce(username,'Joueur') into nb from profiles where id=q.user_id;
  -- 8 temps forts, 4 occasions chacun, en alternance ; tirage au sort de celui qui attaque en premier
  select array_agg(m order by m) into mins from (select distinct (3+floor(random()*86))::int m from generate_series(1,40) limit 8) z;
  first := case when random()<0.5 then 'a' else 'b' end;
  for i in 1..8 loop
    att := case when (i % 2 = 1) = (first='a') then 'a' else 'b' end;
    mom := mom || jsonb_build_object('m', coalesce(mins[i], i*10), 'att', att,
      'actor', case when att='a' then me.cards[7+floor(random()*5)::int] else op.cards[7+floor(random()*5)::int] end,
      'foe',   case when att='a' then op.cards[1+floor(random()*6)::int] else me.cards[1+floor(random()*6)::int] end);
  end loop;
  insert into ranked_duels(a,b,a_name,b_name,a_elo,b_elo,a_cards,b_cards,a_power,b_power,moments,deadline)
  values (p_uid,q.user_id,na,nb,me.elo,op.elo,me.cards,op.cards,pa,pb,mom, now() + interval '20 seconds') returning id into v_id;
  delete from ranked_queue where user_id in (p_uid,q.user_id);
  return v_id;
end $$;

-- le duel en cours d'un joueur (signe de vie + horloge)
create or replace function public.rk_duel_mine(p_uid uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id bigint; d public.ranked_duels;
begin
  select id into v_id from ranked_duels where status='live' and (a=p_uid or b=p_uid) order by created_at desc limit 1;
  if v_id is null then return null; end if;
  perform rk_duel_seen(v_id, p_uid);
  perform rk_duel_tick(v_id);
  select * into d from ranked_duels where id=v_id;
  return rk_duel_view(d, p_uid);
end $$;

-- combien de joueurs cherchent / sont en ligne (affiché pendant la recherche)
create or replace function public.rk_queue_info(p_uid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'searching', (select count(*) from ranked_queue where user_id<>p_uid and beat > now() - interval '7 seconds'),
    'playing',   (select count(*)*2 from ranked_duels where status='live' and deadline > now() - interval '40 seconds'),
    'online',    (select count(*) from profiles where last_seen > now() - interval '3 minutes' and id<>p_uid));
$$;

-- 6) entrer dans la file
create or replace function public.ranked_queue_join()
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); me public.ranked_players; live bigint; v_id bigint; dv jsonb;
begin
  me := rk_me();
  dv := rk_duel_mine(uid); if dv is not null and dv->>'status'='live' then return jsonb_build_object('duel', dv); end if;
  if coalesce(array_length(me.cards,1),0)<>11 then raise exception 'Compose ton onze avant de jouer'; end if;
  if (select count(*) from user_cards where user_id=uid and card_id=any(me.cards) and quantity>0)<>11 then
    raise exception 'Une carte de ton onze n''est plus dans ta collection : modifie ton équipe'; end if;
  for live in select id from ranked_matches where user_id=uid and status='live' loop perform rk_finalize(live,true); end loop;
  me := rk_me();
  if me.today>=60 then raise exception 'Limite de 60 matchs classés par jour atteinte, reviens demain'; end if;
  perform pg_advisory_xact_lock(7781101);                                   -- un seul appariement à la fois
  delete from ranked_queue where beat < now() - interval '30 seconds';      -- ceux qui ont fermé la page
  insert into ranked_queue(user_id,elo) values (uid,me.elo)
    on conflict (user_id) do update set elo=excluded.elo, beat=now(), joined_at=case when ranked_queue.beat < now() - interval '7 seconds' then now() else ranked_queue.joined_at end;
  v_id := rk_duel_match(uid);
  if v_id is not null then perform rk_duel_seen(v_id, uid); return jsonb_build_object('duel', rk_duel_view((select d from ranked_duels d where id=v_id), uid)); end if;
  return jsonb_build_object('waiting', true, 'waited', 0) || rk_queue_info(uid);
end $$;

-- 7) « toujours là » + « quelqu'un est arrivé ? » (toutes les 2 s pendant la recherche)
create or replace function public.ranked_queue_poll()
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); v_id bigint; dv jsonb; w numeric;
begin
  if uid is null then raise exception 'Non connecté'; end if;
  dv := rk_duel_mine(uid); if dv is not null and dv->>'status'='live' then return jsonb_build_object('duel', dv); end if;
  perform pg_advisory_xact_lock(7781101);
  update ranked_queue set beat=now() where user_id=uid returning extract(epoch from (now()-joined_at)) into w;
  if not found then return jsonb_build_object('waiting', false); end if;
  v_id := rk_duel_match(uid);
  if v_id is not null then perform rk_duel_seen(v_id, uid); return jsonb_build_object('duel', rk_duel_view((select d from ranked_duels d where id=v_id), uid)); end if;
  return jsonb_build_object('waiting', true, 'waited', floor(w)::int) || rk_queue_info(uid);
end $$;

-- 8) quitter la file (Annuler). Si un duel vient d'être créé entre-temps, on le renvoie : il faut le jouer.
create or replace function public.ranked_queue_leave()
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); dv jsonb;
begin
  if uid is null then return null; end if;
  perform pg_advisory_xact_lock(7781101);
  delete from ranked_queue where user_id=uid;
  dv := rk_duel_mine(uid); if dv is not null and dv->>'status'='live' then return jsonb_build_object('duel', dv); end if;
  return jsonb_build_object('left', true);
end $$;

-- 9) pendant le duel
create or replace function public.ranked_duel_state(p_id bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); d public.ranked_duels;
begin
  if not exists (select 1 from ranked_duels where id=p_id and (a=uid or b=uid)) then raise exception 'Match introuvable'; end if;
  perform rk_duel_seen(p_id, uid);
  perform rk_duel_tick(p_id);
  select * into d from ranked_duels where id=p_id;
  return rk_duel_view(d, uid);
end $$;

-- p_choice = F (frappe), D (dribble), P (passe). L'attaquant choisit son action, le défenseur celle qu'il anticipe.
create or replace function public.ranked_duel_move(p_id bigint, p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); d public.ranked_duels;
begin
  if p_choice not in ('F','D','P') then raise exception 'Action inconnue'; end if;
  perform rk_duel_seen(p_id, uid);
  perform rk_duel_tick(p_id);                                        -- le tour précédent a peut-être expiré
  select * into d from ranked_duels where id=p_id and (a=uid or b=uid) for update;
  if not found then raise exception 'Match introuvable'; end if;
  if d.status='live' then
    if d.a=uid and d.a_choice is null then update ranked_duels set a_choice=p_choice, a_miss=0 where id=p_id;
    elsif d.b=uid and d.b_choice is null then update ranked_duels set b_choice=p_choice, b_miss=0 where id=p_id; end if;
    perform rk_duel_tick(p_id);                                      -- les deux ont choisi : on résout tout de suite
  end if;
  select * into d from ranked_duels where id=p_id;
  return rk_duel_view(d, uid);
end $$;

create or replace function public.ranked_duel_forfeit(p_id bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); d public.ranked_duels;
begin
  select * into d from ranked_duels where id=p_id and (a=uid or b=uid) for update;
  if not found then return null; end if;
  if d.status='live' then perform rk_duel_finalize(p_id, case when d.a=uid then 'a' else 'b' end); end if;
  select * into d from ranked_duels where id=p_id;
  return rk_duel_view(d, uid);
end $$;

-- reprendre un duel après un rechargement de page
create or replace function public.ranked_duel_live()
returns jsonb language plpgsql security definer set search_path=public as $$
declare dv jsonb;
begin
  if auth.uid() is null then return null; end if;
  dv := rk_duel_mine(auth.uid());
  return case when dv is not null and dv->>'status'='live' then dv end;
end $$;

-- 10) droits : seules ces fonctions sont appelables depuis le site
revoke all on function public.rk_duel_view(public.ranked_duels, uuid) from public, anon, authenticated;
revoke all on function public.rk_duel_finalize(bigint, text) from public, anon, authenticated;
revoke all on function public.rk_duel_tick(bigint) from public, anon, authenticated;
revoke all on function public.rk_duel_seen(bigint, uuid) from public, anon, authenticated;
revoke all on function public.rk_duel_match(uuid) from public, anon, authenticated;
revoke all on function public.rk_duel_mine(uuid) from public, anon, authenticated;
revoke all on function public.rk_queue_info(uuid) from public, anon, authenticated;
revoke all on function public.ranked_queue_join(), public.ranked_queue_poll(), public.ranked_queue_leave(),
  public.ranked_duel_state(bigint), public.ranked_duel_move(bigint, text), public.ranked_duel_forfeit(bigint), public.ranked_duel_live() from public, anon;
grant execute on function public.ranked_queue_join(), public.ranked_queue_poll(), public.ranked_queue_leave(),
  public.ranked_duel_state(bigint), public.ranked_duel_move(bigint, text), public.ranked_duel_forfeit(bigint), public.ranked_duel_live() to authenticated;

notify pgrst, 'reload schema';
