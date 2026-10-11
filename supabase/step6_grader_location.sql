-- =====================================================================
-- Sverdrup Township Road Tracker — Live grader location (opt-in)
-- Only whoever is checked into the grader can share, and only when they
-- turn it on. Just the latest position is kept (no trail / history).
-- Sharing stops automatically when the grader session ends.
-- Safe to run more than once.
-- =====================================================================

create table if not exists public.grader_location (
  id          integer primary key default 1 check (id = 1),  -- one grader, one row
  operator    text,
  lat         double precision,
  lng         double precision,
  heading     real,
  speed_mph   real,
  accuracy_m  real,
  updated_at  timestamptz,
  sharing     boolean not null default false
);
insert into public.grader_location (id) values (1) on conflict (id) do nothing;

alter table public.grader_location enable row level security;
drop policy if exists "app read" on public.grader_location;
create policy "app read" on public.grader_location for select using (true);
grant select on table public.grader_location to anon, authenticated;

create or replace function public.share_grader_location(
  p_operator text, p_lat double precision, p_lng double precision,
  p_heading real, p_speed_mph real, p_accuracy_m real)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from grader_sessions
    where ended_at is null and lower(btrim(operator)) = lower(btrim(coalesce(p_operator, '')))
  ) then
    return json_build_object('ok', false, 'error', 'not_checked_in');
  end if;
  if p_lat is null or p_lng is null or p_lat not between 40 and 47 or p_lng not between -101 and -92 then
    return json_build_object('ok', false, 'error', 'bad_position');
  end if;
  update grader_location
    set operator = btrim(p_operator), lat = p_lat, lng = p_lng,
        heading = p_heading, speed_mph = p_speed_mph, accuracy_m = p_accuracy_m,
        updated_at = now(), sharing = true
    where id = 1;
  return json_build_object('ok', true);
end;
$$;

create or replace function public.stop_grader_location(p_operator text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  update grader_location set sharing = false
    where id = 1 and lower(btrim(coalesce(operator, ''))) = lower(btrim(coalesce(p_operator, '')));
  return json_build_object('ok', true);
end;
$$;

-- When a grader session ends (check-out, take-over, ended by someone), stop sharing
create or replace function public._grader_session_ended()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ended_at is not null and old.ended_at is null then
    update grader_location set sharing = false
      where id = 1 and lower(btrim(coalesce(operator, ''))) = lower(btrim(new.operator));
  end if;
  return new;
end;
$$;
drop trigger if exists grader_session_ended on public.grader_sessions;
create trigger grader_session_ended after update on public.grader_sessions
  for each row execute function public._grader_session_ended();

revoke all on function public.share_grader_location(text, double precision, double precision, real, real, real) from public;
revoke all on function public.stop_grader_location(text) from public;
revoke all on function public._grader_session_ended() from public, anon, authenticated;
grant execute on function public.share_grader_location(text, double precision, double precision, real, real, real) to anon, authenticated;
grant execute on function public.stop_grader_location(text) to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'grader_location'
  ) then
    alter publication supabase_realtime add table public.grader_location;
  end if;
end $$;
