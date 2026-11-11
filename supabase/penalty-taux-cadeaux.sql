-- ============================================================================
-- PrimeZ — Tirs au but, taux des Primes, boosters donnés par l'admin
-- À lancer une fois dans Supabase > SQL Editor. Relançable sans risque.
-- (Remplace penalty-tout-ou-rien.sql : pas besoin de lancer les deux.)
-- ============================================================================

-- ---------- 1) Tirs au but ----------
--  * 5 ballons par niveau réussi (au lieu de 8)
--  * tout ou rien : si tu continues et que tu rates, tu perds toute la cagnotte
--  * frappe dans le rouge de la jauge : le ballon peut partir à côté ou au-dessus,
--    même si le gardien plonge du mauvais côté (jusqu'à 55 % de risque au bord de la jauge)
create or replace function public.pen_shoot(p_id bigint, p_zone int, p_timing numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s pen_sessions%rowtype; lv int; p numeric; t numeric; goal boolean; gk int; outc text; pay int := 0; bal int; p_out numeric;
begin
  select * into s from pen_sessions where id = p_id and user_id = uid for update;
  if not found or s.status <> 'open' then raise exception 'Séance terminée'; end if;
  lv := s.level + 1; t := greatest(0, least(1, coalesce(p_timing, 0)));
  -- zone rouge de la jauge (t < 0,38) : risque de tir non cadré
  p_out := case when t < 0.38 then (0.38 - t) / 0.38 * 0.55 else 0 end;
  if random() < p_out then
    goal := false; outc := 'dehors'; gk := (p_zone + 1 + floor(random() * 4)::int) % 5;
  else
    p := 0.94 - 0.007 * (lv - 1) + 0.10 * (t - 0.5);
    goal := random() < p;
    if goal then gk := (p_zone + 1 + floor(random() * 4)::int) % 5; outc := 'but';
    elsif random() < 0.25 then gk := (p_zone + 2) % 5; outc := case when p_zone in (0,3) then 'transversale' else 'poteau' end;
    else gk := p_zone; outc := 'arret'; end if;
  end if;
  if goal then
    update pen_sessions set level = lv, bank = bank + 5, updated_at = now() where id = s.id returning * into s;
    if lv >= 100 then
      update pen_sessions set status = 'cashed', paid = bank where id = s.id returning * into s; pay := s.bank;
    end if;
  else
    pay := 0;   -- raté : toute la cagnotte est perdue
    update pen_sessions set status = 'lost', paid = pay, updated_at = now() where id = s.id returning * into s;
  end if;
  if pay > 0 then update profiles set balloons = balloons + pay where id = uid; end if;
  select balloons into bal from profiles where id = uid;
  return jsonb_build_object('goal', goal, 'keeper', gk, 'outcome', outc, 'level', s.level, 'bank', s.bank, 'status', s.status, 'paid', pay, 'balloons', bal, 'next', 5);
end $$;
revoke all on function public.pen_shoot(bigint, int, numeric) from public, anon;
grant execute on function public.pen_shoot(bigint, int, numeric) to authenticated;

-- ---------- 2) Primes un peu plus rares (environ un tiers de moins) ----------
--  Coup d'envoi 0,02 % → 0,012 % · Prolongation 0,03 % → 0,02 % · Panthéon 0,0816 % → 0,06 %
--  La différence va aux Communes : le total reste à 100 %.
update public.boosters set rates = jsonb_set(jsonb_set(rates, '{prime}', to_jsonb(0.012)), '{commune}',
  to_jsonb(round(((rates->>'commune')::numeric + (rates->>'prime')::numeric - 0.012), 4))) where id = 'coup-envoi' and (rates->>'prime')::numeric > 0.012;
update public.boosters set rates = jsonb_set(jsonb_set(rates, '{prime}', to_jsonb(0.02)), '{commune}',
  to_jsonb(round(((rates->>'commune')::numeric + (rates->>'prime')::numeric - 0.02), 4))) where id = 'prolongation' and (rates->>'prime')::numeric > 0.02;
update public.boosters set rates = jsonb_set(jsonb_set(rates, '{prime}', to_jsonb(0.06)), '{commune}',
  to_jsonb(round(((rates->>'commune')::numeric + (rates->>'prime')::numeric - 0.06), 4))) where id = 'pantheon' and (rates->>'prime')::numeric > 0.06;

-- ---------- 3) Admin : donner n'importe quel booster (PROMO compris) à un joueur ou à soi ----------
create or replace function public.admin_give_boosters(p_user uuid, p_booster text, p_n int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q int;
begin
  if not public.is_admin() then raise exception 'Réservé aux admins'; end if;
  if p_user is null then raise exception 'Choisis un joueur précis'; end if;
  if not exists (select 1 from boosters where id = p_booster) then raise exception 'Booster introuvable'; end if;
  if coalesce(p_n, 0) < 1 or p_n > 100 then raise exception 'Entre 1 et 100 boosters à la fois'; end if;
  insert into gift_boosters (user_id, booster_id, qty) values (p_user, p_booster, p_n)
    on conflict (user_id, booster_id) do update set qty = gift_boosters.qty + excluded.qty
    returning qty into q;
  return jsonb_build_object('booster', p_booster, 'qty', q);
end $$;
revoke all on function public.admin_give_boosters(uuid, text, int) from public, anon;
grant execute on function public.admin_give_boosters(uuid, text, int) to authenticated;

select id, rates->>'prime' as prime, rates->>'commune' as commune from public.boosters order by price;
notify pgrst, 'reload schema';
