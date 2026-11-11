-- ============================================================================
-- PrimeZ — TIRS AU BUT : tout ou rien
-- Avant : un tir raté laissait la moitié de la cagnotte.
-- Maintenant : si tu choisis de continuer et que tu rates, tu perds toute la cagnotte.
-- Pour la garder, il faut encaisser avant de tirer.
-- À lancer une fois dans Supabase > SQL Editor. Relançable sans risque.
-- ============================================================================
create or replace function public.pen_shoot(p_id bigint, p_zone int, p_timing numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s pen_sessions%rowtype; lv int; p numeric; t numeric; goal boolean; gk int; outc text; pay int := 0; bal int;
begin
  select * into s from pen_sessions where id = p_id and user_id = uid for update;
  if not found or s.status <> 'open' then raise exception 'Séance terminée'; end if;
  lv := s.level + 1; t := greatest(0, least(1, coalesce(p_timing, 0)));
  p := 0.94 - 0.007 * (lv - 1) + 0.10 * (t - 0.5);
  goal := random() < p;
  if goal then
    gk := (p_zone + 1 + floor(random() * 4)::int) % 5; outc := 'but';
    update pen_sessions set level = lv, bank = bank + 8, updated_at = now() where id = s.id returning * into s;
    if lv >= 100 then
      update pen_sessions set status = 'cashed', paid = bank where id = s.id returning * into s; pay := s.bank;
    end if;
  else
    if random() < 0.25 then gk := (p_zone + 2) % 5; outc := case when p_zone in (0,3) then 'transversale' else 'poteau' end;
    else gk := p_zone; outc := 'arret'; end if;
    pay := 0;   -- raté : toute la cagnotte est perdue
    update pen_sessions set status = 'lost', paid = pay, updated_at = now() where id = s.id returning * into s;
  end if;
  if pay > 0 then update profiles set balloons = balloons + pay where id = uid; end if;
  select balloons into bal from profiles where id = uid;
  return jsonb_build_object('goal', goal, 'keeper', gk, 'outcome', outc, 'level', s.level, 'bank', s.bank, 'status', s.status, 'paid', pay, 'balloons', bal, 'next', 8);
end $$;
revoke all on function public.pen_shoot(bigint, int, numeric) from public, anon;
grant execute on function public.pen_shoot(bigint, int, numeric) to authenticated;

notify pgrst, 'reload schema';
