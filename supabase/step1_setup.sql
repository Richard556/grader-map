-- =====================================================================
-- Sverdrup Township Road Tracker — Step 1 database setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run more than once.
--
-- What it does:
--   1. Creates road_status_log (permanent history of every road change)
--   2. Moves the admin PIN to the server (township_secrets, not readable
--      by the app) and adds admin_apply() for settings + resets
--   3. Replaces the Row Level Security policies on the app tables so the
--      public key can only do what the app actually needs
--   4. Adds township_settings to realtime so threshold changes reach
--      every device immediately
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. History log
-- ---------------------------------------------------------------------
create table if not exists public.road_status_log (
  id          uuid primary key default gen_random_uuid(),
  segment_id  text not null,
  road_name   text,
  status      text not null,
  notes       text,
  changed_by  text,
  changed_at  timestamptz not null default now(),  -- when the operator tapped
  synced_at   timestamptz not null default now(),  -- when it reached the server
  source      text not null default 'manual'       -- manual | reset | auto
);

-- New tables in this project aren't exposed to the app automatically
grant select, insert on table public.road_status_log to anon, authenticated;

create index if not exists road_status_log_changed_at_idx on public.road_status_log (changed_at);
create index if not exists road_status_log_segment_idx   on public.road_status_log (segment_id);

-- ---------------------------------------------------------------------
-- 2. Server-side admin PIN
--    Change the PIN any time with:
--      update public.township_secrets set value = 'NEWPIN' where id = 'admin_pin';
-- ---------------------------------------------------------------------
create table if not exists public.township_secrets (
  id    text primary key,
  value text not null
);
insert into public.township_secrets (id, value) values ('admin_pin', '1234')
  on conflict (id) do nothing;

alter table public.township_secrets enable row level security;
-- (no policies = the app's public key cannot read or change it)

create or replace function public.admin_apply(
  p_pin        text,
  p_green      int,
  p_yellow     int,
  p_reset_ids  text[],
  p_by         text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from township_secrets where id = 'admin_pin' and value = p_pin) then
    raise exception 'invalid_pin';
  end if;

  if p_green is null or p_yellow is null or p_green < 1 or p_yellow <= p_green then
    raise exception 'invalid_thresholds';
  end if;

  insert into township_settings (id, green_days, yellow_days)
    values ('cycle_config', p_green, p_yellow)
    on conflict (id) do update
      set green_days = excluded.green_days,
          yellow_days = excluded.yellow_days;

  if p_reset_ids is not null and coalesce(array_length(p_reset_ids, 1), 0) > 0 then
    insert into road_status (segment_id, status, updated_at, updated_by, notes)
      select unnest(p_reset_ids), 'untouched', null, null, ''
      on conflict (segment_id) do update
        set status = 'untouched', updated_at = null, updated_by = null, notes = '';

    insert into road_status_log (segment_id, status, notes, changed_by, source)
      select unnest(p_reset_ids), 'untouched', '', p_by, 'reset';
  end if;
end;
$$;

revoke all on function public.admin_apply(text, int, int, text[], text) from public;
grant execute on function public.admin_apply(text, int, int, text[], text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Row Level Security
--    Removes any existing policies on these four tables, then adds
--    exactly what the app needs.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('road_status', 'road_status_log', 'hazard_pins', 'township_settings')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.road_status       enable row level security;
alter table public.road_status_log   enable row level security;
alter table public.hazard_pins       enable row level security;
alter table public.township_settings enable row level security;

-- road_status: read, create, update (no deletes)
create policy "app read"   on public.road_status for select using (true);
create policy "app insert" on public.road_status for insert with check (true);
create policy "app update" on public.road_status for update using (true) with check (true);

-- road_status_log: read and append only (history can't be edited or erased)
create policy "app read"   on public.road_status_log for select using (true);
create policy "app insert" on public.road_status_log for insert with check (true);

-- hazard_pins: read, create, delete (resolve); no edits
create policy "app read"   on public.hazard_pins for select using (true);
create policy "app insert" on public.hazard_pins for insert with check (true);
create policy "app delete" on public.hazard_pins for delete using (true);

-- township_settings: read only (changes go through admin_apply with the PIN)
create policy "app read"   on public.township_settings for select using (true);

-- ---------------------------------------------------------------------
-- 4. Realtime for settings
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'township_settings'
  ) then
    alter publication supabase_realtime add table public.township_settings;
  end if;
end $$;

-- Quick check — should list the new policies
select tablename, policyname, cmd from pg_policies
where schemaname = 'public'
  and tablename in ('road_status', 'road_status_log', 'hazard_pins', 'township_settings')
order by tablename, cmd;
