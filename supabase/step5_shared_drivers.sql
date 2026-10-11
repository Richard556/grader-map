-- =====================================================================
-- Sverdrup Township Road Tracker — Shared driver list
-- One list of driver names for every device. Names join automatically
-- the first time someone signs in; admins can add or remove names.
-- Safe to run more than once.
-- =====================================================================

create table if not exists public.operators (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
-- "Richard L." and "richard l." are the same driver
create unique index if not exists operators_name_key on public.operators ((lower(btrim(name))));

alter table public.operators enable row level security;
drop policy if exists "app read" on public.operators;
create policy "app read" on public.operators for select using (true);
grant select on table public.operators to anon, authenticated;

-- Called when someone signs in. Returns the name as already spelled on
-- the list (so everyone uses the same spelling), or adds it.
create or replace function public.register_operator(p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_out  text;
begin
  if v_name = '' or length(v_name) > 60 then
    raise exception 'invalid_name';
  end if;
  insert into operators (name) values (v_name)
    on conflict ((lower(btrim(name)))) do update set last_seen = now()
    returning name into v_out;
  return v_out;
end;
$$;

create or replace function public.admin_add_operator(p_pin text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  if v_name = '' or length(v_name) > 60 then return json_build_object('ok', false, 'error', 'invalid_name'); end if;
  insert into operators (name) values (v_name) on conflict ((lower(btrim(name)))) do nothing;
  return json_build_object('ok', true);
end; $$;

-- Removes the name from the list only; history keeps it
create or replace function public.admin_remove_operator(p_pin text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := _admin_pin_check(p_pin);
  n int;
begin
  if v <> 'ok' then return json_build_object('ok', false, 'error', v); end if;
  delete from operators where lower(btrim(name)) = lower(btrim(coalesce(p_name, '')));
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'count', n);
end; $$;

revoke all on function public.register_operator(text) from public;
revoke all on function public.admin_add_operator(text, text) from public;
revoke all on function public.admin_remove_operator(text, text) from public;
grant execute on function public.register_operator(text) to anon, authenticated;
grant execute on function public.admin_add_operator(text, text) to anon, authenticated;
grant execute on function public.admin_remove_operator(text, text) to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'operators'
  ) then
    alter publication supabase_realtime add table public.operators;
  end if;
end $$;
