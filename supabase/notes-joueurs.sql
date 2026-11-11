-- ============================================================================
-- PrimeZ — NOTES DES JOUEURS
--  1) Nouvelle colonne cards.rating : la note d'un joueur fixée à la main dans l'admin
--     (vide = note automatique selon la rareté).
--  2) Nouvelle échelle, la même que sur le site : Commune 76, Rare 79, Élite 82, Légende 85,
--     Mythique 88, Promo 87, Prime 91, GOAT 96 (L.YAMAL PROMO 94).
--     Le Classé (force des équipes, clubs IA) utilise la même échelle.
-- À lancer une fois dans Supabase > SQL Editor. Relançable sans risque.
-- ============================================================================

alter table public.cards add column if not exists rating int;
alter table public.cards drop constraint if exists cards_rating_check;
alter table public.cards add constraint cards_rating_check check (rating is null or rating between 40 and 99);

-- note d'une carte (sans réglage manuel)
create or replace function public.rk_card_rating(p_rarity text, p_name text)
returns int language sql immutable as $$
  select case
    when p_rarity='promo' and p_name ilike 'L.YAMAL%' then 94
    else coalesce((jsonb_build_object('commune',76,'rare',79,'elite',82,'legende',85,'mythique',88,'promo',87,'prime',91,'goat',96)->>p_rarity)::int, 76)
  end;
$$;

-- force d'une équipe : moyenne des notes (réglage manuel compris) + cohésion
do $do$
begin
  if to_regprocedure('public.rk_team_power(integer[])') is not null then
    execute $f$
    create or replace function public.rk_team_power(p_cards int[])
    returns numeric language sql stable as $body$
      with c as (select id, rarity, name, club, league, rating from public.cards where id = any(p_cards)),
      r as (select avg(coalesce(rating, public.rk_card_rating(rarity, name)))::numeric as avg_r from c),
      coh as (
        select coalesce(sum(least(n-1,3)),0)::numeric as club_pts from (select count(*) n from c where club is not null and club<>'' group by club) x
      ),
      lea as (
        select coalesce(sum(least(n-2,3)),0)::numeric as lea_pts from (select count(*) n from c where league is not null and league not in ('','Autres') group by league having count(*)>=3) y
      )
      select r.avg_r + least(coh.club_pts*0.35 + lea.lea_pts*0.2, 4) from r, coh, lea;
    $body$;
    $f$;
  end if;
end $do$;

notify pgrst, 'reload schema';
