-- Plat & Plant: meldingen op een vast tijdstip
-- Voer dit uit in Supabase bij SQL Editor, NA supabase-setup.sql.
-- Het script mag je vaker uitvoeren.

-- ---------- Tabellen ----------
create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  function_url text,
  secret text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  vapid_public text,
  vapid_private jsonb,
  subject text
);
alter table public.push_config enable row level security;
-- Geen regels: alleen de server kan deze tabel lezen.

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  endpoint text not null unique check (endpoint ~ '^https://'),
  p256dh text,
  auth text,
  notify_time time not null default '18:00',
  tz text not null default 'Europe/Amsterdam',
  last_sent date,
  test boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;

-- ---------- Berekening: hoeveel planten hebben vandaag water nodig ----------
create or replace function public.num_or(v text, d numeric) returns numeric
language sql immutable as $$ select case when v ~ '^\d+(\.\d+)?$' then v::numeric else d end $$;

create or replace function public.plants_due_count(h uuid, d date) returns int
language sql stable security definer set search_path = public as $$
  with p as (
    select data,
      greatest(1, least(60, num_or(data->>'waterGroeiDagen', 7))) as g
    from plants where household_id = h
  ), q as (
    select data, g, greatest(1, least(90, num_or(data->>'waterRustDagen', g * 2))) as r from p
  ), iv as (
    select data,
      case when extract(month from d) between 4 and 9 then g
           when extract(month from d) in (3, 10) then round((g + r) / 2.0)
           else r end::int as days
    from q
  )
  select count(*)::int from iv
  where coalesce(data->>'lastWatered', '') !~ '^\d{4}-\d{2}-\d{2}$'
     or (data->>'lastWatered')::date + days <= d;
$$;

-- Welke telefoons moeten nu een melding krijgen? Alleen voor de server.
create or replace function public.push_targets() returns table (id uuid, endpoint text, due int, test boolean)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with cand as (
    select s.id, (now() at time zone s.tz) as lt, s.test
    from push_subscriptions s
    join members m on m.household_id = s.household_id and m.user_id = s.user_id and m.status = 'active'
    where s.test
       or ((now() at time zone s.tz)::time >= s.notify_time
           and (now() at time zone s.tz)::time < s.notify_time + interval '15 minutes'
           and (s.last_sent is null or s.last_sent < (now() at time zone s.tz)::date))
  )
  update push_subscriptions s
     set last_sent = case when c.test then s.last_sent else c.lt::date end, test = false
    from cand c
   where s.id = c.id
  returning s.id, s.endpoint, plants_due_count(s.household_id, c.lt::date), c.test;
end $$;

-- ---------- Acties voor de app ----------
create or replace function public.setup_push(p_household uuid, p_function_url text, p_public text, p_private jsonb, p_subject text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_household) then raise exception 'not_admin'; end if;
  if p_function_url !~ '^https://[a-z0-9.-]+/functions/v1/[a-z0-9_-]+$' then raise exception 'bad_url'; end if;
  insert into push_config (id, function_url, vapid_public, vapid_private, subject)
  values (1, p_function_url, p_public, p_private, p_subject)
  on conflict (id) do update set function_url = excluded.function_url, vapid_public = excluded.vapid_public,
    vapid_private = excluded.vapid_private, subject = excluded.subject;
  delete from push_subscriptions where true; -- oude aanmeldingen horen bij de oude sleutel
end $$;

create or replace function public.push_public_key() returns text
language sql stable security definer set search_path = public as $$
  select vapid_public from push_config where id = 1 and function_url is not null
    and exists (select 1 from members where user_id = auth.uid() and status = 'active');
$$;

create or replace function public.save_subscription(p_household uuid, p_endpoint text, p_p256dh text, p_auth text, p_time text, p_tz text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member(p_household) then raise exception 'not_member'; end if;
  if p_time !~ '^\d{2}:\d{2}$' or p_time::time < '06:00' or p_time::time > '22:00' then raise exception 'bad_time'; end if;
  if not exists (select 1 from pg_timezone_names where name = p_tz) then p_tz := 'Europe/Amsterdam'; end if;
  insert into push_subscriptions (household_id, user_id, endpoint, p256dh, auth, notify_time, tz)
  values (p_household, auth.uid(), p_endpoint, p_p256dh, p_auth, p_time::time, p_tz)
  on conflict (endpoint) do update set household_id = excluded.household_id, user_id = excluded.user_id,
    p256dh = excluded.p256dh, auth = excluded.auth, notify_time = excluded.notify_time, tz = excluded.tz,
    last_sent = case when push_subscriptions.notify_time <> excluded.notify_time then null else push_subscriptions.last_sent end;
end $$;

create or replace function public.delete_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

create or replace function public.push_test(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update push_subscriptions set test = true where endpoint = p_endpoint and user_id = auth.uid();
  if not found then raise exception 'not_found'; end if;
end $$;

-- ---------- Rechten ----------
revoke all on public.push_config, public.push_subscriptions from anon, authenticated;
revoke execute on function public.num_or(text, numeric), public.plants_due_count(uuid, date), public.push_targets(),
  public.setup_push(uuid, text, text, jsonb, text), public.push_public_key(), public.save_subscription(uuid, text, text, text, text, text),
  public.delete_subscription(text), public.push_test(text) from public, anon;
revoke execute on function public.push_targets(), public.plants_due_count(uuid, date) from authenticated;
grant execute on function public.setup_push(uuid, text, text, jsonb, text), public.push_public_key(),
  public.save_subscription(uuid, text, text, text, text, text), public.delete_subscription(text), public.push_test(text)
  to authenticated;

-- ---------- Elke 5 minuten controleren ----------
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'plat-en-plant-meldingen';
select cron.schedule('plat-en-plant-meldingen', '*/5 * * * *', $job$
  select net.http_post(
    url := c.function_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-plat-secret', c.secret),
    body := '{}'::jsonb
  ) from public.push_config c where c.id = 1 and c.function_url is not null;
$job$);
