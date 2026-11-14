-- PrimeZ · numéros des cartes (N°001 = le meilleur joueur) et notes des grandes cartes
-- À lancer une fois dans Supabase > SQL Editor (après notes-joueurs.sql). Relançable sans risque.
--
-- Le numéro affiché en haut de chaque carte suit la note : la meilleure note = N°001, puis dans l'ordre.
-- Dans l'admin Cartes, la case « N° » permet de fixer un numéro à la main (vide = automatique).
-- Les notes ci-dessous ne remplissent que les cartes sans note : celles que tu as réglées à la main ne changent pas.

-- 1) le numéro fixé à la main
alter table public.cards add column if not exists num int;
alter table public.cards drop constraint if exists cards_num_check;
alter table public.cards add constraint cards_num_check check (num is null or num between 1 and 9999);

-- 2) les notes (GOAT 95-97, Prime 90-94, Mythique 86-90, Légende 82-87)
update public.cards c set rating = v.r from (values
  -- GOAT
  ('L.MESSI 11/12', 97), ('C.RONALDO 13/14', 96),
  -- Prime
  ('PELÉ 1970', 94), ('D.MARADONA 85/86', 94), ('PELÉ 1958', 93), ('J.CRUYFF 71/72', 93),
  ('Z.ZIDANE 97/98', 92), ('Z.ZIDANE 05/06', 91), ('C.RONALDO 17/18', 91),
  -- PROMO (Yamal reste la plus forte ; les autres sont des cartes « fun »)
  ('L.YAMAL 25/26', 91), ('P.COUTINHO 2018', 85), ('ROBINHO 2009', 84), ('DOUGLAS COSTA 2016', 84), ('R.CHERKI 2025', 84),
  ('M.RASHFORD 2023', 83), ('A.TAARABT 2011', 82), ('N.LANG 2021', 82), ('A.SAINT-MAXIMIN 2020', 82),
  -- Mythique
  ('M.VAN BASTEN 88/89', 90), ('T.HENRY 02/03', 90), ('A.DI STÉFANO 1957', 90), ('F.PUSKÁS 1960', 90), ('F.BECKENBAUER 74/75', 90),
  ('NEYMAR JR 15/16', 89), ('ROMÁRIO 93/94', 89), ('ZICO 1981', 89),
  ('G.BUFFON 05/06', 88), ('I.CASILLAS 09/10', 87), ('E.HAZARD 18/19', 87), ('A.PIRLO 12/13', 87),
  ('A.GRIEZMANN 15/16', 86), ('S.BUSQUETS 10/11', 86), ('D.ALVES 08/09', 86), ('MARCELO 13/14', 86),
  -- Légende
  ('L.YASHIN 1963', 87), ('B.CHARLTON 1966', 87), ('F.BARESI 88/89', 87),
  ('A.DEL PIERO 97/98', 86), ('D.BERGKAMP 97/98', 86), ('G.WEAH 94/95', 86), ('H.STOICHKOV 93/94', 86), ('H.KANE 23/24', 86),
  ('R.CARLOS 02/03', 86), ('K.RUMMENIGGE 80/81', 86), ('SÓCRATES 1982', 86), ('VINÍCIUS JR 23/24', 86),
  ('D.DROGBA 09/10', 85), ('F.CANNAVARO 05/06', 85), ('O.KAHN 00/01', 85), ('F.TOTTI 06/07', 85), ('A.SHEARER 94/95', 85),
  ('R.VAN NISTELROOY 02/03', 85), ('E.CANTONA 95/96', 85), ('RAÚL 00/01', 85), ('P.VIEIRA 03/04', 85), ('CAFU 01/02', 85),
  ('D.ZOFF 82/83', 85), ('P.ROSSI 81/82', 85), ('P.LAHM 12/13', 85), ('RODRI 23/24', 85), ('O.DEMBÉLÉ 24/25', 85),
  ('T.KROOS 23/24', 85), ('J.BELLINGHAM 23/24', 85), ('S.ETO''O 09/10', 85), ('A.NESTA 06/07', 85), ('R.KOPA 1958', 85),
  ('B.MOORE 1966', 85), ('K.DALGLISH 83/84', 85), ('G.RIVERA 1969', 85), ('JAIRZINHO 1970', 85),
  ('P.ČECH 04/05', 84), ('M.OWEN 00/01', 84), ('P.SCHOLES 02/03', 84), ('R.KEANE 98/99', 84), ('S.MANÉ 18/19', 84),
  ('R.GIGGS 98/99', 84), ('D.BECKHAM 98/99', 84), ('G.HAGI 93/94', 84), ('FALCÃO 82/83', 84), ('B.SCHWEINSTEIGER 13/14', 84),
  ('L.THURAM 97/98', 84), ('C.SEEDORF 02/03', 84), ('J.TERRY 04/05', 84), ('R.FERDINAND 07/08', 84), ('N.VIDIĆ 08/09', 84),
  ('X.ALONSO 10/11', 84), ('T.MÜLLER 12/13', 84), ('C.PUYOL 08/09', 84), ('F.TORRES 07/08', 84), ('J.ZANETTI 09/10', 84),
  ('M.SAMMER 95/96', 84), ('J.P.PAPIN 90/91', 84), ('D.LAW 1964', 84), ('K.KEEGAN 1979', 84), ('G.FACCHETTI 1965', 84),
  ('M.KEMPES 1978', 84),
  ('G.PIQUÉ 10/11', 83), ('P.POGBA 15/16', 83), ('Á.DI MARÍA', 83), ('R.VARANE 17/18', 83), ('R.KOEMAN 91/92', 83),
  ('DECO 03/04', 83), ('E.VAN DER SAR 07/08', 83), ('F.INZAGHI 06/07', 83), ('A.HAKIMI 24/25', 83), ('C.MAKÉLÉLÉ 01/02', 83),
  ('J.STAM 98/99', 83), ('JUNINHO 05/06', 83),
  ('PEPE 16/17', 82), ('K.NAVAS 17/18', 82), ('G.GATTUSO 06/07', 82), ('B.LIZARAZU 00/01', 82), ('A.COLE 11/12', 82),
  ('P.EVRA 07/08', 82), ('M.BALOTELLI 09/10', 82)
) v(name, r)
where c.name = v.name and c.rating is null;

notify pgrst, 'reload schema';
