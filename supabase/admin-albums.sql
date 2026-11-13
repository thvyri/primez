-- PrimeZ · gestion des albums depuis l'admin (onglet « Albums » du menu admin)
-- À lancer une fois dans Supabase > SQL Editor, après pack-du-jour-defis-albums.sql.

-- 1) Yamal : l'album « La nouvelle vague » prend sa carte PROMO, la carte L.YAMAL 24/25 ajoutée en trop est retirée
update public.albums a set card_ids = array(
  select case when x = (select id from public.cards where name = 'L.YAMAL 24/25' limit 1)
              then (select id from public.cards where name = 'L.YAMAL 25/26' and rarity = 'promo' limit 1) else x end
  from unnest(a.card_ids) with ordinality u(x, o) order by o)
where a.id = 'nouvelle-vague';
update public.cards set active = false where name = 'L.YAMAL 24/25';

-- 2) l'admin voit aussi les albums masqués
drop policy if exists "albums admin" on public.albums;
create policy "albums admin" on public.albums for select using (public.is_admin());

-- 3) créer ou modifier un album
create or replace function public.admin_album_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(coalesce(p->>'id', '')), ''); v_title text := nullif(trim(coalesce(p->>'title', '')), '');
        v_cards int[]; r albums%rowtype;
begin
  if not public.is_admin() then raise exception 'Réservé à l''admin'; end if;
  if v_title is null then raise exception 'Donne un titre à l''album'; end if;
  select coalesce(array_agg(x::int order by o), '{}') into v_cards
    from jsonb_array_elements_text(coalesce(p->'card_ids', '[]'::jsonb)) with ordinality e(x, o);
  if coalesce(array_length(v_cards, 1), 0) < 2 then raise exception 'Mets au moins 2 cartes dans l''album'; end if;
  if v_id is null then
    v_id := trim(both '-' from lower(regexp_replace(translate(v_title, 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', 'aaaeeeeiioouuucAAAEEEEIIOOUUUC'), '[^A-Za-z0-9]+', '-', 'g')));
    if v_id = '' or exists (select 1 from albums where id = v_id) then v_id := v_id || '-' || substr(md5(random()::text), 1, 4); end if;
  end if;
  insert into albums (id, title, descr, card_ids, reward_balloons, reward_booster, reward_qty, reward_card, sort, active)
  values (v_id, v_title, nullif(trim(coalesce(p->>'descr', '')), ''), v_cards,
          greatest(coalesce((p->>'reward_balloons')::int, 0), 0), nullif(p->>'reward_booster', ''),
          greatest(coalesce((p->>'reward_qty')::int, 1), 1), nullif(p->>'reward_card', '')::int,
          coalesce((p->>'sort')::int, 0), coalesce((p->>'active')::boolean, true))
  on conflict (id) do update set title = excluded.title, descr = excluded.descr, card_ids = excluded.card_ids,
    reward_balloons = excluded.reward_balloons, reward_booster = excluded.reward_booster, reward_qty = excluded.reward_qty,
    reward_card = excluded.reward_card, sort = excluded.sort, active = excluded.active
  returning * into r;
  return to_jsonb(r);
end $$;

-- 4) supprimer un album (les joueurs qui l'avaient complété gardent leurs récompenses)
create or replace function public.admin_album_delete(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''admin'; end if;
  delete from albums where id = p_id;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_album_save(jsonb)', 'admin_album_delete(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
