-- duels.vanguard — database schema for Supabase (Postgres)
--
-- How to run: Supabase dashboard → SQL Editor → New query → paste this whole file → Run.
-- Safe to run again: tables use "if not exists" and functions/policies are replaced.
--
-- What it creates
--   profiles        one row per account (public username), created automatically on sign-up
--   matches_played  one row per finished match: the deck used (card ids + counts), its nation,
--                   its grade 3 vanguard and the result. Decks themselves stay in the player's browser;
--                   only the list used in a match is recorded, to build the Meta page.
--   meta_*()        public read-only statistics (no user ids ever leave the database)
--   username_available(), delete_my_account()

-------------------------------------------------------------------------------
-- profiles
-------------------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  username   text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_username_lower on public.profiles (lower(username));

alter table public.profiles enable row level security;

drop policy if exists "Usernames are public" on public.profiles;
create policy "Usernames are public" on public.profiles
  for select using (true);

drop policy if exists "Players update their own profile" on public.profiles;
create policy "Players update their own profile" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- players may only change their username; rows are created by the trigger below
revoke insert, update, delete on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (username) on public.profiles to authenticated;

-- create the profile when an account is created (email/password or Google)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base text;
  candidate text;
  tries int := 0;
begin
  base := coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'name', ''),
    split_part(coalesce(new.email, ''), '@', 1)
  );
  base := trim(both '_' from regexp_replace(coalesce(base, ''), '[^A-Za-z0-9_]+', '_', 'g'));
  if length(base) < 3 then base := 'player'; end if;
  base := left(base, 15);

  candidate := base;
  while exists (select 1 from public.profiles p where lower(p.username) = lower(candidate)) loop
    tries := tries + 1;
    if tries > 25 then
      candidate := 'player_' || left(replace(new.id::text, '-', ''), 12);
      exit;
    end if;
    candidate := base || (1000 + floor(random() * 9000))::int::text;
  end loop;

  insert into public.profiles (id, username) values (new.id, candidate);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- lets the sign-up form say "name taken" before creating the account
create or replace function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_username ~ '^[A-Za-z0-9_]{3,20}$'
     and not exists (select 1 from public.profiles p where lower(p.username) = lower(p_username));
$$;

-- account deletion (removes the profile and recorded matches through "on delete cascade")
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

-------------------------------------------------------------------------------
-- matches_played
-------------------------------------------------------------------------------
create table if not exists public.matches_played (
  id        bigint generated always as identity primary key,
  user_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  played_at timestamptz not null default now(),
  mode      text not null check (mode in ('bot', 'online')),
  nation    text not null check (nation in ('DE', 'DS', 'BG', 'KS', 'ST', 'LM', 'NN')),
  vanguard  text not null check (vanguard ~ '^[A-Z]{1,3}-[A-Z0-9]{2,8}/[A-Z0-9]{1,6}$'),
  cards     jsonb not null check (jsonb_typeof(cards) = 'object'),
  result    text check (result in ('win', 'loss', 'draw')),
  turns     int check (turns between 0 and 500)
);
create index if not exists matches_played_at on public.matches_played (played_at desc);
create index if not exists matches_played_user on public.matches_played (user_id, played_at desc);

alter table public.matches_played enable row level security;

drop policy if exists "Players read their own matches" on public.matches_played;
create policy "Players read their own matches" on public.matches_played
  for select to authenticated
  using ((select auth.uid()) = user_id);

-- the browser can only record its own matches against the bot;
-- online matches will be written by the match server (service role), never by the browser
drop policy if exists "Players record their own bot matches" on public.matches_played;
create policy "Players record their own bot matches" on public.matches_played
  for insert to authenticated
  with check ((select auth.uid()) = user_id and mode = 'bot');

revoke all on public.matches_played from anon, authenticated;
grant select, insert on public.matches_played to authenticated;

-- validate the deck list and slow down spam
create or replace function public.check_match_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  k text;
  v jsonb;
  copies numeric;
  total int := 0;
  recent int;
begin
  new.played_at := now();

  if (select count(*) from jsonb_object_keys(new.cards)) > 60 then
    raise exception 'Deck has too many different cards';
  end if;

  for k, v in select * from jsonb_each(new.cards) loop
    if k !~ '^[A-Z]{1,3}-[A-Z0-9]{2,8}/[A-Z0-9]{1,6}$' then
      raise exception 'Invalid card id: %', left(k, 40);
    end if;
    if jsonb_typeof(v) <> 'number' then
      raise exception 'Invalid copy count for %', k;
    end if;
    copies := (v #>> '{}')::numeric;
    if copies <> trunc(copies) or copies < 1 or copies > 4 then
      raise exception 'Invalid copy count for %', k;
    end if;
    total := total + copies::int;
  end loop;

  if total < 1 or total > 60 then
    raise exception 'Invalid deck size';
  end if;
  if not new.cards ? new.vanguard then
    raise exception 'Vanguard is not in the deck';
  end if;

  if new.mode = 'bot' then
    select count(*) into recent
    from public.matches_played m
    where m.user_id = new.user_id and m.played_at > now() - interval '10 minutes';
    if recent >= 20 then
      raise exception 'Too many matches recorded in a short time';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists matches_played_check on public.matches_played;
create trigger matches_played_check
  before insert on public.matches_played
  for each row execute function public.check_match_row();

-------------------------------------------------------------------------------
-- public statistics for the Meta page
--   p_days: look-back window (1–365), p_mode: 'all' | 'bot' | 'online', p_nation: null = every nation
-------------------------------------------------------------------------------
create or replace function public.meta_nations(p_days int default 30, p_mode text default 'all')
returns table (nation text, matches bigint, players bigint, share numeric, win_rate numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select m.nation,
         count(*),
         count(distinct m.user_id),
         round(100.0 * count(*) / sum(count(*)) over (), 1),
         round(100.0 * count(*) filter (where m.result = 'win')
               / nullif(count(*) filter (where m.result in ('win', 'loss')), 0), 1)
  from public.matches_played m
  where m.played_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365))
    and (coalesce(p_mode, 'all') = 'all' or m.mode = p_mode)
  group by m.nation
  order by 2 desc, 1;
$$;

create or replace function public.meta_vanguards(p_days int default 30, p_mode text default 'all', p_nation text default null)
returns table (vanguard text, nation text, matches bigint, players bigint, share numeric, win_rate numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select m.vanguard,
         m.nation,
         count(*),
         count(distinct m.user_id),
         round(100.0 * count(*) / sum(count(*)) over (), 1),
         round(100.0 * count(*) filter (where m.result = 'win')
               / nullif(count(*) filter (where m.result in ('win', 'loss')), 0), 1)
  from public.matches_played m
  where m.played_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365))
    and (coalesce(p_mode, 'all') = 'all' or m.mode = p_mode)
    and (p_nation is null or m.nation = p_nation)
  group by m.vanguard, m.nation
  order by 3 desc, 1
  limit 15;
$$;

create or replace function public.meta_cards(p_days int default 30, p_mode text default 'all', p_nation text default null)
returns table (card text, decks bigint, inclusion numeric, avg_copies numeric)
language sql
stable
security definer
set search_path = ''
as $$
  with m as (
    select m.cards
    from public.matches_played m
    where m.played_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365))
      and (coalesce(p_mode, 'all') = 'all' or m.mode = p_mode)
      and (p_nation is null or m.nation = p_nation)
  ), n as (select count(*) as total from m)
  select e.key,
         count(*),
         round(100.0 * count(*) / max(n.total), 1),
         round(avg((e.value #>> '{}')::numeric), 1)
  from m
  cross join lateral jsonb_each(m.cards) as e
  cross join n
  group by e.key
  order by 2 desc, 4 desc, 1
  limit 40;
$$;

revoke all on function public.meta_nations(int, text) from public;
revoke all on function public.meta_vanguards(int, text, text) from public;
revoke all on function public.meta_cards(int, text, text) from public;
revoke all on function public.username_available(text) from public;
revoke all on function public.delete_my_account() from public;
revoke all on function public.handle_new_user() from public;
revoke all on function public.check_match_row() from public;
revoke all on function public.delete_my_account() from anon;
revoke all on function public.handle_new_user() from anon, authenticated;
revoke all on function public.check_match_row() from anon, authenticated;

grant execute on function public.meta_nations(int, text) to anon, authenticated;
grant execute on function public.meta_vanguards(int, text, text) to anon, authenticated;
grant execute on function public.meta_cards(int, text, text) to anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;
