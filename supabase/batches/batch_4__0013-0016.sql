-- Run this AFTER the previous batch. Paste into Supabase SQL editor and Run.

-- ===== 0013_pending_profile_visibility.sql =====
-- Friend requests embed the other person's profile, but a pending request is
-- between two people who aren't accepted friends yet — so the prior
-- "friends read profiles" (accepted-only) policy returned null and every
-- incoming/outgoing request showed "@someone". Broaden profile reads to
-- anyone sharing a friendship row of any status. Harmless: a pending
-- requester already typed your exact username to reach you.

create or replace function public.has_friendship_edge(p_other uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists (
    select 1 from friendships
    where (requester = auth.uid() and addressee = p_other)
       or (requester = p_other and addressee = auth.uid())
  );
$$;

revoke all on function public.has_friendship_edge(uuid) from public, anon;
grant execute on function public.has_friendship_edge(uuid) to authenticated;

drop policy "friends read profiles" on public.profiles;
create policy "friendship profiles readable" on public.profiles
  for select to authenticated
  using (has_friendship_edge(id));


-- ===== 0014_membership.sql =====
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


-- ===== 0015_trip_photos.sql =====
-- Trip photos: your camera-roll photos taken at a planned place, attached to
-- your review and visible to people on the trip/list. Privacy model in
-- docs/trip-photos-architecture.md: nothing auto-uploads, EXIF is stripped
-- client-side, the bucket is private, and downloads go through a signed-URL
-- function after a visibility check.

create table public.photos (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  storage_path text not null,          -- {owner_id}/{uuid}.jpg
  place_id uuid references public.places (id) on delete set null,
  trip_id uuid references public.trips (id) on delete cascade,
  list_id uuid references public.lists (id) on delete cascade,
  taken_at timestamptz,
  latitude double precision,
  longitude double precision,
  created_at timestamptz not null default now()
);

create index photos_place_idx on public.photos (place_id);
create index photos_trip_idx on public.photos (trip_id);
create index photos_owner_idx on public.photos (owner_id);

alter table public.photos enable row level security;

-- Visible to the owner and to anyone who can access the trip (or list) the
-- photo belongs to. Trip/list access is the membership from migration 0014.
create policy "photos readable" on public.photos
  for select to authenticated
  using (
    owner_id = auth.uid()
    or (trip_id is not null and can_access_trip(trip_id))
    or (list_id is not null and can_read_list(list_id))
  );

-- You upload your own photos, and only onto a trip/list you're actually on.
create policy "photos insert" on public.photos
  for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (trip_id is null or can_access_trip(trip_id))
    and (list_id is null or can_read_list(list_id))
  );

create policy "photos delete" on public.photos
  for delete to authenticated using (owner_id = auth.uid());

-- Private storage bucket for the image objects.
insert into storage.buckets (id, name, public)
values ('trip-photos', 'trip-photos', false)
on conflict (id) do nothing;

-- Write only under your own {user_id}/ prefix; the object name's first path
-- segment must be the uploader's id.
create policy "trip photos upload own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'trip-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "trip photos delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'trip-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Reads are NOT granted here on purpose: downloads go through the
-- get-photo-url edge function, which checks photos-table visibility and mints
-- a short-lived signed URL with the service role.


-- ===== 0016_events.sql =====
-- Events: a single day of activities you share with people, who RSVP.
-- Lighter than a trip — one date, an optional start time, a guest list with
-- going/maybe/declined, and stops that link to the places you're going.

create table public.events (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  emoji text,
  event_date date not null,
  start_time time,
  note text,
  created_at timestamptz not null default now()
);
create index events_owner_idx on public.events (owner_id, event_date);

-- Stops = the places/activities. A save-backed stop carries that save's
-- place, map link, website, and phone; a custom stop is freeform.
create table public.event_stops (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  save_id uuid references public.saves (id) on delete set null,
  title text,
  start_time time,
  position int not null default 0,
  created_at timestamptz not null default now(),
  check (save_id is not null or title is not null)
);
create index event_stops_event_idx on public.event_stops (event_id, position);

create table public.event_guests (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'invited' check (status in ('invited', 'going', 'maybe', 'declined')),
  invited_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index event_guests_user_idx on public.event_guests (user_id);

-- Access helpers (definer, query only guest table → no recursion) ----------

create or replace function public.is_event_guest(p_event uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from event_guests where event_id = p_event and user_id = auth.uid()); $$;

create or replace function public.event_owner_is_me(p_event uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select exists (select 1 from events where id = p_event and owner_id = auth.uid()); $$;

create or replace function public.can_access_event(p_event uuid)
returns boolean language sql security definer stable set search_path = public
as $$ select public.event_owner_is_me(p_event) or public.is_event_guest(p_event); $$;

grant execute on function
  public.is_event_guest(uuid), public.event_owner_is_me(uuid), public.can_access_event(uuid)
  to authenticated;

-- RLS ----------------------------------------------------------------------

alter table public.events enable row level security;
create policy "events readable" on public.events
  for select to authenticated using (owner_id = auth.uid() or is_event_guest(id));
create policy "events insert" on public.events
  for insert to authenticated with check (owner_id = auth.uid());
create policy "events update" on public.events
  for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "events delete" on public.events
  for delete to authenticated using (owner_id = auth.uid());

alter table public.event_stops enable row level security;
create policy "event stops readable" on public.event_stops
  for select to authenticated using (can_access_event(event_id));
create policy "event stops insert" on public.event_stops
  for insert to authenticated with check (event_owner_is_me(event_id));
create policy "event stops update" on public.event_stops
  for update to authenticated using (event_owner_is_me(event_id)) with check (event_owner_is_me(event_id));
create policy "event stops delete" on public.event_stops
  for delete to authenticated using (event_owner_is_me(event_id));

alter table public.event_guests enable row level security;
create policy "event guests readable" on public.event_guests
  for select to authenticated using (can_access_event(event_id));
-- Owner invites accepted friends.
create policy "event guests invite" on public.event_guests
  for insert to authenticated
  with check (invited_by = auth.uid() and event_owner_is_me(event_id) and is_friend(user_id));
-- A guest updates their OWN rsvp; the owner may update any guest row.
create policy "event guests rsvp" on public.event_guests
  for update to authenticated
  using (user_id = auth.uid() or event_owner_is_me(event_id))
  with check (user_id = auth.uid() or event_owner_is_me(event_id));
create policy "event guests remove" on public.event_guests
  for delete to authenticated using (event_owner_is_me(event_id) or user_id = auth.uid());


