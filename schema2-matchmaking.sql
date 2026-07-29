-- =========================================================
-- Fútbol Multiplayer — M4: matchmaking + resultado de partido
-- Correr en: Supabase Dashboard > SQL Editor > New query > Run
-- (requiere haber corrido schema.sql antes)
-- =========================================================

-- 1) Cola de emparejamiento
create table if not exists public.matchmaking_queue (
  id uuid primary key default gen_random_uuid(),
  team_id uuid unique not null references public.teams(id) on delete cascade,
  division_id smallint not null references public.divisions(id),
  status text not null default 'waiting',
  match_id uuid references public.matches(id),
  created_at timestamptz not null default now()
);

alter table public.matchmaking_queue enable row level security;

drop policy if exists queue_select_own on public.matchmaking_queue;
create policy queue_select_own on public.matchmaking_queue for select
  using (team_id in (select id from public.teams where owner_id = auth.uid()));

drop policy if exists queue_delete_own on public.matchmaking_queue;
create policy queue_delete_own on public.matchmaking_queue for delete
  using (team_id in (select id from public.teams where owner_id = auth.uid()));

-- Habilitar Realtime (postgres changes) sobre esta tabla
do $$
begin
  alter publication supabase_realtime add table public.matchmaking_queue;
exception when duplicate_object then null;
end $$;

-- 2) Buscar rival de la misma división o quedar en cola
create or replace function public.find_or_queue_match(p_team_id uuid)
returns table(match_id uuid, opponent_team_id uuid, opponent_name text)
language plpgsql
security definer set search_path = public
as $$
declare
  v_owner uuid;
  v_division smallint;
  v_season uuid;
  v_opponent record;
  v_match_id uuid;
begin
  select owner_id, division_id into v_owner, v_division from public.teams where id = p_team_id;
  if v_owner is null or v_owner <> auth.uid() then
    raise exception 'No autorizado';
  end if;

  delete from public.matchmaking_queue where team_id = p_team_id and status = 'waiting';

  select q.id, q.team_id into v_opponent
  from public.matchmaking_queue q
  where q.division_id = v_division
    and q.status = 'waiting'
    and q.team_id <> p_team_id
  order by q.created_at
  limit 1
  for update skip locked;

  if v_opponent.team_id is not null then
    select s.id into v_season from public.seasons s where s.division_id = v_division and s.status = 'open' limit 1;

    insert into public.matches (season_id, home_team_id, away_team_id, status, played_at)
    values (v_season, v_opponent.team_id, p_team_id, 'live', now())
    returning id into v_match_id;

    update public.matchmaking_queue set status = 'matched', match_id = v_match_id where id = v_opponent.id;

    return query
      select v_match_id, v_opponent.team_id, t.name from public.teams t where t.id = v_opponent.team_id;
  else
    insert into public.matchmaking_queue (team_id, division_id, status)
    values (p_team_id, v_division, 'waiting');
    return;
  end if;
end;
$$;

grant execute on function public.find_or_queue_match(uuid) to authenticated;

-- 3) Cerrar un partido y volcar el resultado a la tabla de posiciones
create or replace function public.report_match_result(p_match_id uuid, p_home_score int, p_away_score int)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_home uuid; v_away uuid; v_status text; v_caller_team uuid;
begin
  select home_team_id, away_team_id, status into v_home, v_away, v_status
  from public.matches where id = p_match_id;

  if v_status is null then raise exception 'Partido no encontrado'; end if;
  if v_status = 'finished' then return; end if;

  select id into v_caller_team from public.teams
  where owner_id = auth.uid() and id in (v_home, v_away);
  if v_caller_team is null then raise exception 'No autorizado'; end if;

  update public.matches
  set home_score = p_home_score, away_score = p_away_score, status = 'finished', played_at = now()
  where id = p_match_id;

  if p_home_score > p_away_score then
    update public.teams set points = points + 3, wins = wins + 1,
      goals_for = goals_for + p_home_score, goals_against = goals_against + p_away_score where id = v_home;
    update public.teams set losses = losses + 1,
      goals_for = goals_for + p_away_score, goals_against = goals_against + p_home_score where id = v_away;
  elsif p_home_score < p_away_score then
    update public.teams set losses = losses + 1,
      goals_for = goals_for + p_home_score, goals_against = goals_against + p_away_score where id = v_home;
    update public.teams set points = points + 3, wins = wins + 1,
      goals_for = goals_for + p_away_score, goals_against = goals_against + p_home_score where id = v_away;
  else
    update public.teams set points = points + 1, draws = draws + 1,
      goals_for = goals_for + p_home_score, goals_against = goals_against + p_away_score where id = v_home;
    update public.teams set points = points + 1, draws = draws + 1,
      goals_for = goals_for + p_away_score, goals_against = goals_against + p_home_score where id = v_away;
  end if;
end;
$$;

grant execute on function public.report_match_result(uuid, int, int) to authenticated;
