-- =====================================================================
-- Sverdrup Township Road Tracker — Grader check-in
-- One grader, one active session at a time. Every session is kept as
-- history (who ran it, when, and how it ended).
-- Safe to run more than once.
-- =====================================================================

create table if not exists public.grader_sessions (
  id          uuid primary key default gen_random_uuid(),
  operator    text not null,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  ended_by    text,
  end_reason  text            -- checked_out | ended_by_other | taken_over
);

-- Only one session can be open at a time
create unique index if not exists grader_sessions_one_active
  on public.grader_sessions ((true)) where ended_at is null;
create index if not exists grader_sessions_started_idx on public.grader_sessions (started_at);

alter table public.grader_sessions enable row level security;
drop policy if exists "app read" on public.grader_sessions;
create policy "app read" on public.grader_sessions for select using (true);
-- The app can read sessions; all changes go through the two functions below
grant select on table public.grader_sessions to anon, authenticated;

-- Check in. If someone else is in the grader, fails with grader_in_use
-- unless p_take_over is true (then their session is closed first).
create or replace function public.grader_check_in(p_operator text, p_take_over boolean default false)
returns public.grader_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name   text := btrim(coalesce(p_operator, ''));
  v_active grader_sessions;
  v_new    grader_sessions;
begin
  if v_name = '' or length(v_name) > 60 then
    raise exception 'invalid_operator';
  end if;

  select * into v_active from grader_sessions where ended_at is null for update;

  if found then
    if lower(v_active.operator) = lower(v_name) then
      return v_active;  -- already checked in
    end if;
    if not coalesce(p_take_over, false) then
      raise exception 'grader_in_use:%', v_active.operator;
    end if;
    update grader_sessions
      set ended_at = now(), ended_by = v_name, end_reason = 'taken_over'
      where id = v_active.id;
  end if;

  begin
    insert into grader_sessions (operator) values (v_name) returning * into v_new;
  exception when unique_violation then
    select * into v_active from grader_sessions where ended_at is null;
    raise exception 'grader_in_use:%', coalesce(v_active.operator, 'someone');
  end;

  return v_new;
end;
$$;

-- Check out (or end someone else's forgotten session)
create or replace function public.grader_check_out(p_by text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := nullif(btrim(coalesce(p_by, '')), '');
begin
  update grader_sessions
    set ended_at = now(),
        ended_by = v_name,
        end_reason = case when lower(operator) = lower(coalesce(v_name, '')) then 'checked_out' else 'ended_by_other' end
    where ended_at is null;
end;
$$;

revoke all on function public.grader_check_in(text, boolean) from public;
revoke all on function public.grader_check_out(text) from public;
grant execute on function public.grader_check_in(text, boolean) to anon, authenticated;
grant execute on function public.grader_check_out(text) to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'grader_sessions'
  ) then
    alter publication supabase_realtime add table public.grader_sessions;
  end if;
end $$;
