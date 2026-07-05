-- Shared trips and lists: invite accepted friends as members (viewer or
-- editor). Owner rights stay derived from trips.user_id / lists.user_id;
-- members are additive. See docs/trip-photos-architecture.md (Path A) and
-- friends-and-sharing-architecture.md (§D3, §D4).

create table public.trip_members (
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'viewer' check (role in ('viewer', 'editor')),
  invited_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);
create index trip_members_user_idx on public.trip_members (user_id);

create table public.list_members (
  list_id uuid not null references public.lists (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'viewer' check (role in ('viewer', 'editor')),
  invited_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  primary key (list_id, user_id)
);
create index list_members_user_idx on public.list_members (user_id);

-- Membership helpers query only the member tables (never trips/lists), so
-- there's no chance of policy recursion. Definer to bypass member-table RLS.
create or replace function public.is_trip_member(p_trip uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from trip_members where trip_id = p_trip and user_id = auth.uid()); $$;

create or replace function public.is_trip_editor(p_trip uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from trip_members where trip_id = p_trip and user_id = auth.uid() and role = 'editor'); $$;

create or replace function public.is_list_member(p_list uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from list_members where list_id = p_list and user_id = auth.uid()); $$;

create or replace function public.is_list_editor(p_list uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from list_members where list_id = p_list and user_id = auth.uid() and role = 'editor'); $$;

create or replace function public.trip_owner_is_me(p_trip uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from trips where id = p_trip and user_id = auth.uid()); $$;

create or replace function public.list_owner_is_me(p_list uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from lists where id = p_list and user_id = auth.uid()); $$;

create or replace function public.can_access_trip(p_trip uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select public.trip_owner_is_me(p_trip) or public.is_trip_member(p_trip); $$;

create or replace function public.can_edit_trip(p_trip uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select public.trip_owner_is_me(p_trip) or public.is_trip_editor(p_trip); $$;

create or replace function public.can_edit_list(p_list uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select public.list_owner_is_me(p_list) or public.is_list_editor(p_list); $$;

grant execute on function
  public.is_trip_member(uuid), public.is_trip_editor(uuid),
  public.is_list_member(uuid), public.is_list_editor(uuid),
  public.trip_owner_is_me(uuid), public.list_owner_is_me(uuid),
  public.can_access_trip(uuid), public.can_edit_trip(uuid),
  public.can_edit_list(uuid)
  to authenticated;

-- Trips: owner or member reads; owner-only lifecycle -----------------------

drop policy "own trips" on public.trips;
create policy "trips readable" on public.trips
  for select to authenticated
  using (user_id = auth.uid() or is_trip_member(id));
create policy "trips insert" on public.trips
  for insert to authenticated with check (user_id = auth.uid());
create policy "trips update" on public.trips
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "trips delete" on public.trips
  for delete to authenticated using (user_id = auth.uid());

drop policy "own trip items" on public.trip_items;
create policy "trip items readable" on public.trip_items
  for select to authenticated using (can_access_trip(trip_id));
create policy "trip items insert" on public.trip_items
  for insert to authenticated with check (can_edit_trip(trip_id));
create policy "trip items update" on public.trip_items
  for update to authenticated using (can_edit_trip(trip_id)) with check (can_edit_trip(trip_id));
create policy "trip items delete" on public.trip_items
  for delete to authenticated using (can_edit_trip(trip_id));

alter table public.trip_members enable row level security;
create policy "trip members readable" on public.trip_members
  for select to authenticated using (can_access_trip(trip_id));
-- Owner invites; invitee must be an accepted friend of the owner.
create policy "trip members invite" on public.trip_members
  for insert to authenticated
  with check (invited_by = auth.uid() and trip_owner_is_me(trip_id) and is_friend(user_id));
create policy "trip members role" on public.trip_members
  for update to authenticated using (trip_owner_is_me(trip_id)) with check (trip_owner_is_me(trip_id));
-- Owner removes anyone; a member can remove themselves (leave).
create policy "trip members remove" on public.trip_members
  for delete to authenticated using (trip_owner_is_me(trip_id) or user_id = auth.uid());

-- Lists: extend existing read (owner / friends-visible) with member access,
-- and let editor-members write items ---------------------------------------

create or replace function public.can_read_list(p_list uuid)
returns boolean language sql security definer stable set search_path = public
as $$
  select exists (
    select 1 from lists
    where id = p_list
      and (user_id = auth.uid()
        or (visibility = 'friends'
            and public.is_friend(user_id)
            and not public.is_sharing_paused(user_id)))
  ) or public.is_list_member(p_list);
$$;

drop policy "list items writable" on public.list_items;
drop policy "list items deletable" on public.list_items;
create policy "list items insert" on public.list_items
  for insert to authenticated with check (can_edit_list(list_id));
create policy "list items delete" on public.list_items
  for delete to authenticated using (can_edit_list(list_id));

alter table public.list_members enable row level security;
create policy "list members readable" on public.list_members
  for select to authenticated using (can_read_list(list_id));
create policy "list members invite" on public.list_members
  for insert to authenticated
  with check (invited_by = auth.uid() and list_owner_is_me(list_id) and is_friend(user_id));
create policy "list members role" on public.list_members
  for update to authenticated using (list_owner_is_me(list_id)) with check (list_owner_is_me(list_id));
create policy "list members remove" on public.list_members
  for delete to authenticated using (list_owner_is_me(list_id) or user_id = auth.uid());
