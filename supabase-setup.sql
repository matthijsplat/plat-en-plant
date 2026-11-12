-- Gietgenoten: inrichting van de gedeelde database
-- Plak dit hele script in Supabase bij SQL Editor en klik op Run.
-- Het script mag je vaker uitvoeren; bestaande gegevens blijven staan.

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabellen ----------
create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.household_secrets (
  household_id uuid primary key references public.households on delete cascade,
  recovery_hash text not null
);

create table if not exists public.members (
  household_id uuid not null references public.households on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  role text not null default 'member' check (role in ('admin', 'member')),
  status text not null default 'pending' check (status in ('pending', 'active')),
  created_at timestamptz not null default now(),
  primary key (household_id, user_id)
);
create unique index if not exists one_admin_per_household on public.members (household_id) where role = 'admin';

create table if not exists public.plants (
  id text primary key check (id ~ '^[a-z0-9]{6,40}$'),
  household_id uuid not null references public.households on delete cascade,
  data jsonb not null default '{}'::jsonb check (octet_length(data::text) < 30000),
  updated_at timestamptz not null default now()
);
create index if not exists plants_household on public.plants (household_id);

create table if not exists public.photos (
  plant_id text primary key references public.plants on delete cascade,
  household_id uuid not null references public.households on delete cascade,
  data text not null check (octet_length(data) < 700000),
  version bigint not null
);
create index if not exists photos_household on public.photos (household_id);

alter table public.households enable row level security;
alter table public.household_secrets enable row level security;
alter table public.members enable row level security;
alter table public.plants enable row level security;
alter table public.photos enable row level security;

-- ---------- Hulpfuncties ----------
create or replace function public.is_member(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where household_id = h and user_id = auth.uid() and status = 'active');
$$;

create or replace function public.is_admin(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where household_id = h and user_id = auth.uid() and status = 'active' and role = 'admin');
$$;

create or replace function public.new_code(n int) returns text
language sql volatile set search_path = public, extensions as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (get_byte(gen_random_bytes(1), 0) % 32) + 1, 1), '')
  from generate_series(1, n);
$$;

-- ---------- Toegangsregels ----------
-- Alleen geaccepteerde leden zien en wijzigen de planten van hun huishouden.
drop policy if exists households_read on public.households;
create policy households_read on public.households for select to authenticated using (public.is_member(id));

drop policy if exists members_read on public.members;
create policy members_read on public.members for select to authenticated
  using (user_id = auth.uid() or public.is_member(household_id));

drop policy if exists plants_all on public.plants;
create policy plants_all on public.plants for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

drop policy if exists photos_all on public.photos;
create policy photos_all on public.photos for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));
-- household_secrets heeft bewust geen regels: niemand kan die tabel direct lezen.

-- ---------- Acties ----------
create or replace function public.create_household(p_name text, p_display text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare h uuid; inv text; rec text; nm text := left(trim(p_name), 60); me text := left(trim(p_display), 40);
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if exists (select 1 from households) then raise exception 'household_exists'; end if;
  if nm = '' or me = '' then raise exception 'empty_name'; end if;
  inv := new_code(8); rec := new_code(16);
  insert into households (name, invite_code) values (nm, inv) returning id into h;
  insert into household_secrets values (h, crypt(rec, gen_salt('bf')));
  insert into members (household_id, user_id, display_name, role, status) values (h, auth.uid(), me, 'admin', 'active');
  return jsonb_build_object('household', h, 'name', nm, 'invite', inv,
    'recovery', substr(rec,1,4)||'-'||substr(rec,5,4)||'-'||substr(rec,9,4)||'-'||substr(rec,13,4));
end $$;

create or replace function public.join_household(p_code text, p_display text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h households%rowtype; m members%rowtype; me text := left(trim(p_display), 40);
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if me = '' then raise exception 'empty_name'; end if;
  select * into h from households where invite_code = upper(trim(p_code));
  if not found then raise exception 'bad_code'; end if;
  insert into members (household_id, user_id, display_name) values (h.id, auth.uid(), me)
    on conflict (household_id, user_id) do update set display_name = excluded.display_name
    returning * into m;
  return jsonb_build_object('household', h.id, 'name', h.name, 'status', m.status, 'role', m.role);
end $$;

create or replace function public.my_status(p_household uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('status', m.status, 'role', m.role, 'name', h.name, 'display', m.display_name,
           'invite', case when m.status = 'active' then h.invite_code end)
  from members m join households h on h.id = m.household_id
  where m.household_id = p_household and m.user_id = auth.uid();
$$;

create or replace function public.approve_member(p_household uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_household) then raise exception 'not_admin'; end if;
  update members set status = 'active' where household_id = p_household and user_id = p_user;
end $$;

create or replace function public.remove_member(p_household uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_household) then raise exception 'not_admin'; end if;
  if p_user = auth.uid() then raise exception 'cannot_remove_self'; end if;
  delete from members where household_id = p_household and user_id = p_user;
end $$;

create or replace function public.transfer_admin(p_household uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_household) then raise exception 'not_admin'; end if;
  if not exists (select 1 from members where household_id = p_household and user_id = p_user and status = 'active') then
    raise exception 'not_active_member'; end if;
  update members set role = 'member' where household_id = p_household and user_id = auth.uid();
  update members set role = 'admin' where household_id = p_household and user_id = p_user;
end $$;

create or replace function public.leave_household(p_household uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if is_admin(p_household) then raise exception 'admin_cannot_leave'; end if;
  delete from members where household_id = p_household and user_id = auth.uid();
end $$;

create or replace function public.new_invite(p_household uuid) returns text
language plpgsql security definer set search_path = public as $$
declare inv text;
begin
  if not is_admin(p_household) then raise exception 'not_admin'; end if;
  inv := new_code(8);
  update households set invite_code = inv where id = p_household;
  return inv;
end $$;

create or replace function public.recover_admin(p_recovery text, p_display text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare h households%rowtype; code text := upper(regexp_replace(coalesce(p_recovery, ''), '[^A-Za-z0-9]', '', 'g'));
        me text := left(trim(p_display), 40);
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if me = '' then raise exception 'empty_name'; end if;
  select hh.* into h from households hh join household_secrets s on s.household_id = hh.id
    where s.recovery_hash = crypt(code, s.recovery_hash);
  if not found then perform pg_sleep(1); raise exception 'bad_recovery'; end if;
  update members set role = 'member' where household_id = h.id and role = 'admin';
  insert into members (household_id, user_id, display_name, role, status) values (h.id, auth.uid(), me, 'admin', 'active')
    on conflict (household_id, user_id) do update set role = 'admin', status = 'active', display_name = excluded.display_name;
  return jsonb_build_object('household', h.id, 'name', h.name, 'invite', h.invite_code);
end $$;

-- Plant bijwerken zonder wijzigingen van een huisgenoot te overschrijven.
create or replace function public.patch_plant(p_id text, p_household uuid, p_fields jsonb, p_create boolean default false) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare result jsonb; f jsonb := coalesce(p_fields, '{}'::jsonb) - 'id' - 'foto' - 'fotoV';
begin
  if not is_member(p_household) then raise exception 'not_member'; end if;
  update plants set data = data || f, updated_at = now() where id = p_id and household_id = p_household returning data into result;
  if not found then
    if not p_create then raise exception 'not_found'; end if;
    insert into plants (id, household_id, data) values (p_id, p_household, f) returning data into result;
  end if;
  return result;
end $$;

-- ---------- Logboek voor de ranglijst ----------
create table if not exists public.waterings (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  plant_id text not null,
  user_id uuid references auth.users on delete set null default auth.uid(),
  display_name text not null check (char_length(display_name) between 1 and 40),
  kind text not null default 'water' check (kind in ('water', 'voeding')),
  day date not null,
  created_at timestamptz not null default now()
);
create index if not exists waterings_household_day on public.waterings (household_id, day);
alter table public.waterings enable row level security;

drop policy if exists waterings_read on public.waterings;
create policy waterings_read on public.waterings for select to authenticated using (public.is_member(household_id));
drop policy if exists waterings_add on public.waterings;
create policy waterings_add on public.waterings for insert to authenticated
  with check (public.is_member(household_id) and user_id = auth.uid());
drop policy if exists waterings_undo on public.waterings;
create policy waterings_undo on public.waterings for delete to authenticated
  using (user_id = auth.uid() and created_at > now() - interval '1 day');

-- Ranglijst over een periode: per persoon (op naam) het aantal keer water en voeding.
-- Op naam, zodat iemand die opnieuw meedoet (bijvoorbeeld na een nieuw webadres) niet dubbel in de lijst staat.
create or replace function public.stats(p_household uuid, p_from date, p_to date) returns jsonb
language sql stable security invoker set search_path = public as $$
  with w as (
    select w.*, coalesce(m.display_name, w.display_name) as nm
    from waterings w
    left join members m on m.household_id = w.household_id and m.user_id = w.user_id
    where w.household_id = p_household and w.day between p_from and p_to and is_member(p_household)
  )
  select coalesce(jsonb_agg(row_to_json(t) order by t.water desc, t.voeding desc, t.name), '[]'::jsonb)
  from (
    select (array_agg(user_id order by created_at desc))[1] as user_id,
      (array_agg(nm order by created_at desc))[1] as name,
      count(*) filter (where kind = 'water')::int as water,
      count(*) filter (where kind = 'voeding')::int as voeding,
      count(distinct plant_id) filter (where kind = 'water')::int as planten
    from w
    group by lower(trim(nm))
  ) t;
$$;

-- ---------- Planten die nog in de lijst ontbreken ----------
create table if not exists public.plant_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid references public.households on delete set null,
  name text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now()
);
alter table public.plant_requests enable row level security;
drop policy if exists plant_requests_add on public.plant_requests;
create policy plant_requests_add on public.plant_requests for insert to authenticated
  with check (public.is_member(household_id));
-- Bewust geen leesregel: alleen de beheerder van het project ziet de verzoeken, in het Supabase-dashboard (Table Editor, plant_requests).

-- ---------- Rechten ----------
revoke execute on all functions in schema public from public, anon;
grant execute on function public.is_member(uuid), public.is_admin(uuid), public.create_household(text, text),
  public.join_household(text, text), public.my_status(uuid), public.approve_member(uuid, uuid),
  public.remove_member(uuid, uuid), public.transfer_admin(uuid, uuid), public.leave_household(uuid),
  public.new_invite(uuid), public.recover_admin(text, text), public.patch_plant(text, uuid, jsonb, boolean),
  public.stats(uuid, date, date)
  to authenticated;
revoke execute on function public.new_code(int) from authenticated;
grant usage on schema public to authenticated;
grant select on public.households, public.members to authenticated;
grant select, insert, update, delete on public.plants, public.photos to authenticated;
grant select, insert, delete on public.waterings to authenticated;
grant insert on public.plant_requests to authenticated;
revoke all on public.plant_requests from anon;
revoke update on public.waterings from authenticated;
revoke all on public.households, public.members, public.plants, public.photos, public.waterings from anon;
revoke all on public.household_secrets from anon, authenticated;
revoke insert, update, delete on public.households, public.members from anon, authenticated;
