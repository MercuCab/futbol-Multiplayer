-- =========================================================
-- Fútbol Multiplayer — Esquema inicial (M2 + M3)
-- Correr esto una sola vez en: Supabase Dashboard > SQL Editor > New query > Run
-- =========================================================

-- 1) Divisiones (espejo de la Liga Argentina, tier 1 = más alta)
create table if not exists public.divisions (
  id smallint primary key,
  name text not null,
  tier smallint not null unique
);

insert into public.divisions (id, name, tier) values
  (1, 'Primera División', 1),
  (2, 'Primera Nacional', 2),
  (3, 'Primera B', 3),
  (4, 'Primera C', 4),
  (5, 'Primera D', 5)
on conflict (id) do nothing;

-- 2) Perfiles (uno por usuario de auth)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  created_at timestamptz not null default now()
);

-- Crea el perfil automáticamente cuando alguien se registra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3) Temporadas (una temporada abierta por división)
create table if not exists public.seasons (
  id uuid primary key default gen_random_uuid(),
  division_id smallint not null references public.divisions(id),
  number int not null default 1,
  status text not null default 'open',
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

insert into public.seasons (division_id, number, status)
select id, 1, 'open' from public.divisions
where not exists (select 1 from public.seasons s where s.division_id = public.divisions.id);

-- 4) Equipos (uno por jugador)
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid unique not null references auth.users(id) on delete cascade,
  name text not null,
  division_id smallint not null references public.divisions(id),
  points int not null default 0,
  wins int not null default 0,
  draws int not null default 0,
  losses int not null default 0,
  goals_for int not null default 0,
  goals_against int not null default 0,
  created_at timestamptz not null default now()
);

-- Todo equipo nuevo arranca en la división más baja (tier más alto = 5), sin importar lo que mande el cliente
create or replace function public.assign_starting_division()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  select id into new.division_id from public.divisions order by tier desc limit 1;
  return new;
end;
$$;

drop trigger if exists teams_assign_division on public.teams;
create trigger teams_assign_division
  before insert on public.teams
  for each row execute function public.assign_starting_division();

-- 5) Partidos (se completa en M4/M5)
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  season_id uuid references public.seasons(id),
  home_team_id uuid references public.teams(id),
  away_team_id uuid references public.teams(id),
  home_score int,
  away_score int,
  played_at timestamptz,
  status text not null default 'scheduled'
);

-- =========================================================
-- Row Level Security
-- =========================================================
alter table public.divisions enable row level security;
alter table public.profiles enable row level security;
alter table public.seasons enable row level security;
alter table public.teams enable row level security;
alter table public.matches enable row level security;

-- Lectura pública (tabla de posiciones, nombres de equipos/divisiones son visibles para todos)
drop policy if exists divisions_select_all on public.divisions;
create policy divisions_select_all on public.divisions for select using (true);

drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_all on public.profiles for select using (true);

drop policy if exists seasons_select_all on public.seasons;
create policy seasons_select_all on public.seasons for select using (true);

drop policy if exists teams_select_all on public.teams;
create policy teams_select_all on public.teams for select using (true);

drop policy if exists matches_select_all on public.matches;
create policy matches_select_all on public.matches for select using (true);

-- Cada usuario puede crear su propio equipo (uno solo, por el unique en owner_id) y editar su propio perfil
drop policy if exists teams_insert_own on public.teams;
create policy teams_insert_own on public.teams for insert with check (auth.uid() = owner_id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update using (auth.uid() = id);
