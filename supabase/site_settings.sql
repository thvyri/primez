-- =====================================================================
--  PrimeZ · réglages du site modifiables depuis le menu admin (ex. afficher ou cacher la cagnotte)
--  À exécuter une fois dans Supabase : SQL Editor → New query → coller → Run.
-- =====================================================================
create table if not exists public.site_settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);
alter table public.site_settings enable row level security;
drop policy if exists "site_settings lecture" on public.site_settings;
create policy "site_settings lecture" on public.site_settings for select using (true);
grant select on public.site_settings to anon, authenticated;

-- par défaut la cagnotte est cachée : l'admin la rend publique quand il veut
insert into public.site_settings(key,value) values ('cagnotte_public','false'::jsonb) on conflict (key) do nothing;

create or replace function public.set_site_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not coalesce((select is_admin from profiles where id=auth.uid()),false) then raise exception 'Réservé aux admins'; end if;
  insert into site_settings(key,value,updated_at) values (p_key,p_value,now())
  on conflict (key) do update set value=excluded.value, updated_at=now();
end $$;
grant execute on function public.set_site_setting(text,jsonb) to authenticated;

notify pgrst, 'reload schema';
