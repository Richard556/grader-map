-- =====================================================================
-- Sverdrup Township Road Tracker — Admin panel + GPS auto-blade
-- Safe to run more than once.
--
--   * PIN lockout: 5 wrong PINs within 15 minutes locks admin for 15 min
--   * Admin functions (all need the PIN, all return {ok, error, ...}):
--       admin_verify, admin_stats, admin_save_cycle, admin_reset_roads,
--       admin_delete_history, admin_delete_sessions, admin_delete_hazards,
--       admin_change_pin, admin_save_autoblade
--   * Auto-blade settings stored in township_settings
--   * Replaces the older admin_apply()
-- =====================================================================

-- ---------------------------------------------------------------------
-- Auto-blade settings
-- ---------------------------------------------------------------------
alter table public.township_settings
  add column if not exists autoblade_min_mph  numeric not null default 2,
  add column if not exists autoblade_max_mph  numeric not null default 15,
  add column if not exists autoblade_coverage integer not null default 80,
  add column if not exists autoblade_mode     text    not null default 'auto';  -- auto | confirm

-- ---------------------------------------------------------------------
-- PIN check with lockout
-- ---------------------------------------------------------------------
create table if not exists public.admin_lockout (
  id            integer primary key default 1,
  failures      integer not null default 0,
  first_failure timestamptz,
  locked_until  timestamptz
);
insert into public.admin_lockout (id) values (1) on conflict (id) do nothing;
alter table public.admin_lockout enable row level security;  -- no policies: app can't see it

-- Returns 'ok', 'invalid_pin' or 'locked'. Callers return the result
-- instead of raising, so failed attempts are actually recorded.
create or replace function public._admin_pin_check(p_pin text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  l admin_lockout;
begin
  select * into l from admin_lockout where id = 1 for update;
  if l.locked_until is not null and l.locked_until > now() then
    return 'locked';
  end if;

  if exists (select 1 from township_secrets where id = 'admin_pin' and value = coalesce(p_pin, '')) then
    update admin_lockout set failures = 0, first_failure = null, locked_until = null where id = 1;
    return 'ok';
  end if;

  if l.first_failure is null or l.first_failure < now() - interval '15 minutes' then
    update admin_lockout set failures = 1, first_failure = now(), locked_until = null where id = 1;
  else
    update admin_lockout
      set failures = l.failures + 1,
          locked_until = case when l.failures + 1 >= 5 then now() + interval '15 minutes' else null end
      where id = 1;
  end if;
  return 'invalid_pin';
end;
$$;
revoke all on function public._admin_pin_check(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Admin functions
-- ---------------------------------------------------------------------
drop function if exists public.admin_apply(text, int, int, text[], text);

create or replace function public.admin_verify(p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
begin
  return json_build_object('ok', v = 'ok', 'error', nullif(v, 'ok'));
end; $$;

create or replace function public.admin_stats(p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  return json_build_object(
    'ok', true,
    'history_total', (select count(*) from road_status_log),
    'sessions_total', (select count(*) from grader_sessions where ended_at is not null),
    'hazards_total', (select count(*) from hazard_pins),
    'operators', coalesce((
      select json_agg(x order by lower(x.name)) from (
        select name, sum(h)::int as history, sum(s)::int as sessions from (
          select coalesce(changed_by, '(none)') as name, 1 as h, 0 as s from road_status_log
          union all
          select operator, 0, 1 from grader_sessions where ended_at is not null
        ) u group by name
      ) x), '[]'::json)
  );
end; $$;

create or replace function public.admin_save_cycle(p_pin text, p_green int, p_yellow int)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if p_green is null or p_yellow is null or p_green < 1 or p_yellow <= p_green or p_yellow > 365 then
    return json_build_object('ok', false, 'error', 'invalid_thresholds');
  end if;
  insert into township_settings (id, green_days, yellow_days) values ('cycle_config', p_green, p_yellow)
    on conflict (id) do update set green_days = excluded.green_days, yellow_days = excluded.yellow_days;
  return json_build_object('ok', true);
end; $$;

create or replace function public.admin_reset_roads(p_pin text, p_ids text[], p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
  n int := coalesce(array_length(p_ids, 1), 0);
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if n > 0 then
    insert into road_status (segment_id, status, updated_at, updated_by, notes)
      select unnest(p_ids), 'untouched', null, null, ''
      on conflict (segment_id) do update
        set status = 'untouched', updated_at = null, updated_by = null, notes = '';
    insert into road_status_log (segment_id, status, notes, changed_by, source)
      select unnest(p_ids), 'untouched', '', nullif(btrim(coalesce(p_by, '')), ''), 'reset';
  end if;
  return json_build_object('ok', true, 'count', n);
end; $$;

-- p_preview = true only counts; false deletes. Operator null = everyone.
create or replace function public.admin_delete_history(
  p_pin text, p_from timestamptz, p_to timestamptz, p_operator text, p_preview boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
  n int;
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if p_preview then
    select count(*) into n from road_status_log
      where changed_at >= p_from and changed_at < p_to
        and (p_operator is null or lower(coalesce(changed_by, '(none)')) = lower(p_operator));
  else
    delete from road_status_log
      where changed_at >= p_from and changed_at < p_to
        and (p_operator is null or lower(coalesce(changed_by, '(none)')) = lower(p_operator));
    get diagnostics n = row_count;
  end if;
  return json_build_object('ok', true, 'count', n);
end; $$;

-- Only finished sessions; whoever is in the grader right now is never deleted
create or replace function public.admin_delete_sessions(
  p_pin text, p_from timestamptz, p_to timestamptz, p_operator text, p_preview boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
  n int;
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if p_preview then
    select count(*) into n from grader_sessions
      where ended_at is not null and started_at >= p_from and started_at < p_to
        and (p_operator is null or lower(operator) = lower(p_operator));
  else
    delete from grader_sessions
      where ended_at is not null and started_at >= p_from and started_at < p_to
        and (p_operator is null or lower(operator) = lower(p_operator));
    get diagnostics n = row_count;
  end if;
  return json_build_object('ok', true, 'count', n);
end; $$;

-- Returns the deleted ids so the app can remove their photos
create or replace function public.admin_delete_hazards(p_pin text, p_ids text[])
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
  deleted json;
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  with d as (delete from hazard_pins where id = any(p_ids) returning id, photo_url)
    select coalesce(json_agg(json_build_object('id', id, 'photo', photo_url is not null)), '[]'::json) into deleted from d;
  return json_build_object('ok', true, 'deleted', deleted);
end; $$;

create or replace function public.admin_change_pin(p_pin text, p_new_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if p_new_pin is null or length(btrim(p_new_pin)) < 4 or length(p_new_pin) > 20 then
    return json_build_object('ok', false, 'error', 'invalid_new_pin');
  end if;
  update township_secrets set value = btrim(p_new_pin) where id = 'admin_pin';
  return json_build_object('ok', true);
end; $$;

create or replace function public.admin_save_autoblade(
  p_pin text, p_min_mph numeric, p_max_mph numeric, p_coverage int, p_mode text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if p_min_mph is null or p_max_mph is null or p_min_mph < 0 or p_max_mph <= p_min_mph or p_max_mph > 60
     or p_coverage is null or p_coverage < 30 or p_coverage > 100
     or p_mode not in ('auto', 'confirm') then
    return json_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  update township_settings
    set autoblade_min_mph = p_min_mph, autoblade_max_mph = p_max_mph,
        autoblade_coverage = p_coverage, autoblade_mode = p_mode
    where id = 'cycle_config';
  return json_build_object('ok', true);
end; $$;

-- Permissions: the app may call these (they check the PIN themselves)
do $$
declare f text;
begin
  foreach f in array array[
    'admin_verify(text)', 'admin_stats(text)', 'admin_save_cycle(text,int,int)',
    'admin_reset_roads(text,text[],text)',
    'admin_delete_history(text,timestamptz,timestamptz,text,boolean)',
    'admin_delete_sessions(text,timestamptz,timestamptz,text,boolean)',
    'admin_delete_hazards(text,text[])', 'admin_change_pin(text,text)',
    'admin_save_autoblade(text,numeric,numeric,int,text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
