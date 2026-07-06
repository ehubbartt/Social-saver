-- ============================================================================
-- SocialSaver / Kove — consolidated schema (migrations 0001–0016)
-- Run ONCE in a fresh Supabase project (SQL editor). Do NOT also run the
-- individual migration files. Statements run in order; end state is identical
-- to applying each migration sequentially.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 0001_initial.sql
-- ─────────────────────────────────────────────────────────────────────────
-- SocialSaver initial schema
-- Apply with: supabase db push (or run in the SQL editor)

create type content_type as enum (
  'place', 'restaurant', 'recipe', 'activity', 'shopping', 'event', 'other'
);

create type save_status as enum ('pending', 'processed', 'failed');

-- Profiles mirror auth.users so app data never joins against the auth schema.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Canonical places, shared across users so the same restaurant saved by two
-- people resolves to one row (enables future "trending" / "friends" layers).
create table public.places (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  city text,
  country text,
  latitude double precision,
  longitude double precision,
  created_at timestamptz not null default now(),
  unique (name, city, country)
);

create table public.saves (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  source_url text not null,
  source_platform text not null default 'unknown',
  title text,
  summary text,
  thumbnail_url text,
  author_name text,
  content_type content_type not null default 'other',
  status save_status not null default 'pending',
  created_at timestamptz not null default now(),
  unique (user_id, source_url)
);

create table public.save_places (
  save_id uuid not null references public.saves (id) on delete cascade,
  place_id uuid not null references public.places (id) on delete cascade,
  primary key (save_id, place_id)
);

create table public.lists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  emoji text,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

create table public.list_items (
  list_id uuid not null references public.lists (id) on delete cascade,
  save_id uuid not null references public.saves (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (list_id, save_id)
);

create index saves_user_created_idx on public.saves (user_id, created_at desc);
create index save_places_place_idx on public.save_places (place_id);
create index list_items_save_idx on public.list_items (save_id);

-- Row level security ---------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.places enable row level security;
alter table public.saves enable row level security;
alter table public.save_places enable row level security;
alter table public.lists enable row level security;
alter table public.list_items enable row level security;

create policy "own profile" on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- Places are shared reference data: any signed-in user may read or add them;
-- rows are only mutated by the ingest function.
create policy "places are readable" on public.places
  for select to authenticated using (true);
create policy "places are insertable" on public.places
  for insert to authenticated with check (true);

create policy "own saves" on public.saves
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own save places" on public.save_places
  for all using (
    exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid())
  );

create policy "own lists" on public.lists
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own list items" on public.list_items
  for all using (
    exists (select 1 from public.lists l where l.id = list_id and l.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.lists l where l.id = list_id and l.user_id = auth.uid())
  );


-- ─────────────────────────────────────────────────────────────────────────
-- 0002_add_recipe.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Recipe payload extracted from cooking videos:
-- { "ingredients": ["..."], "steps": ["..."] }
alter table public.saves add column recipe jsonb;


-- ─────────────────────────────────────────────────────────────────────────
-- 0003_links_and_contact.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Contact info on places, found via web search during ingest.
alter table public.places
  add column website text,
  add column phone text;

-- Non-place links mentioned in a video: app recommendations, products,
-- booking pages, official sites.
create table public.save_links (
  id uuid primary key default gen_random_uuid(),
  save_id uuid not null references public.saves (id) on delete cascade,
  title text not null,
  url text not null,
  kind text not null default 'website',
  note text,
  created_at timestamptz not null default now()
);

create index save_links_save_idx on public.save_links (save_id);

alter table public.save_links enable row level security;

create policy "own save links" on public.save_links
  for all using (
    exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid())
  );


-- ─────────────────────────────────────────────────────────────────────────
-- 0004_fix_place_upserts.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Unique constraints never match rows with NULLs, so places without a known
-- city/country were duplicated on every save instead of deduplicating.
-- Store '' instead of NULL so the (name, city, country) constraint works.
update public.places set city = '' where city is null;
update public.places set country = '' where country is null;

alter table public.places
  alter column city set default '',
  alter column city set not null,
  alter column country set default '',
  alter column country set not null;

-- The ingest pipeline upserts places (insert ... on conflict do update).
-- Without an update policy, RLS rejected the update path the second time any
-- user saved an already-known place, failing the whole ingest.
create policy "places are updatable" on public.places
  for update to authenticated using (true) with check (true);


-- ─────────────────────────────────────────────────────────────────────────
-- 0005_add_note.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Personal note on a save (e.g. "Mia recommended this", "book ahead").
alter table public.saves add column note text;


-- ─────────────────────────────────────────────────────────────────────────
-- 0006_trips.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Trip planning: upcoming trips with a day-by-day itinerary built from saves.

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  destination text not null,
  emoji text,
  start_date date,
  end_date date,
  created_at timestamptz not null default now()
);

-- A save placed on a trip. day_index is 1-based; null means the "Ideas"
-- bucket (in the trip, not yet scheduled to a day).
create table public.trip_items (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  save_id uuid not null references public.saves (id) on delete cascade,
  day_index int,
  position int not null default 0,
  note text,
  created_at timestamptz not null default now(),
  unique (trip_id, save_id)
);

create index trip_items_trip_idx on public.trip_items (trip_id, day_index, position);

alter table public.trips enable row level security;
alter table public.trip_items enable row level security;

create policy "own trips" on public.trips
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own trip items" on public.trip_items
  for all using (
    exists (select 1 from public.trips t where t.id = trip_id and t.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.trips t where t.id = trip_id and t.user_id = auth.uid())
  );


-- ─────────────────────────────────────────────────────────────────────────
-- 0007_trip_scheduling.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Trip items grow into general itinerary entries:
-- - kind 'save' rows wrap a saved video (save_id set)
-- - flight/hotel/transport/custom rows are standalone (save_id null) with
--   their own title, optional scheduled time, and optional location
alter table public.trip_items
  alter column save_id drop not null,
  add column kind text not null default 'save',
  add column title text,
  add column detail text,
  add column start_time time,
  add column latitude double precision,
  add column longitude double precision,
  add column address text;


-- ─────────────────────────────────────────────────────────────────────────
-- 0008_trip_item_constraints.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Database-level backstop for the trip agent and app clients: whatever a
-- caller manages to send, trip items stay structurally coherent.
alter table public.trip_items
  add constraint trip_items_kind_check
    check (kind in ('save', 'flight', 'hotel', 'transport', 'custom')),
  add constraint trip_items_save_presence
    check ((kind = 'save') = (save_id is not null)),
  add constraint trip_items_day_range
    check (day_index is null or (day_index >= 1 and day_index <= 31));


-- ─────────────────────────────────────────────────────────────────────────
-- 0009_place_discovery.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Community discovery: other videos saved for the same place.
--
-- Saves stay private (RLS untouched). This security-definer function is the
-- only cross-user surface, and it returns ONLY public video metadata — the
-- link, title, thumbnail, and platform — never the saver's identity, notes,
-- or lists. Deduplicated by video URL.
create or replace function public.videos_for_place(p_place_id uuid)
returns table (
  title text,
  thumbnail_url text,
  source_url text,
  source_platform text
)
language sql
security definer
stable
set search_path = public
as $$
  select distinct on (s.source_url)
    s.title,
    s.thumbnail_url,
    s.source_url,
    s.source_platform
  from saves s
  join save_places sp on sp.save_id = s.id
  where sp.place_id = p_place_id
    and s.status = 'processed'
    and s.user_id <> auth.uid()
  order by s.source_url, s.created_at desc
  limit 20;
$$;

revoke all on function public.videos_for_place(uuid) from public, anon;
grant execute on function public.videos_for_place(uuid) to authenticated;


-- ─────────────────────────────────────────────────────────────────────────
-- 0010_place_reviews.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Place reviews: star rating + a "worth it?" verdict + an optional written
-- take. One review per user per place, editable. Unlike saves (private),
-- reviews are community content by design: any signed-in user can read them;
-- no display identity is attached (the app shows "You" only on your own).

create table public.place_reviews (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  worth_it boolean not null,
  body text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (place_id, user_id)
);

create index place_reviews_place_idx on public.place_reviews (place_id, created_at desc);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger place_reviews_touch
  before update on public.place_reviews
  for each row execute function public.touch_updated_at();

alter table public.place_reviews enable row level security;

create policy "reviews are readable" on public.place_reviews
  for select to authenticated using (true);

create policy "insert own review" on public.place_reviews
  for insert to authenticated with check (user_id = auth.uid());

create policy "update own review" on public.place_reviews
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "delete own review" on public.place_reviews
  for delete to authenticated using (user_id = auth.uid());


-- ─────────────────────────────────────────────────────────────────────────
-- 0011_friends.sql
-- ─────────────────────────────────────────────────────────────────────────
-- Friends foundation: claimable usernames, exact-match discovery, and
-- friend requests. See docs/friends-and-sharing-architecture.md.

-- Usernames: unique case-insensitively. Claimed from the Profile tab.
create unique index profiles_username_lower_idx
  on public.profiles (lower(username))
  where username is not null;

-- Discovery is EXACT-match only, via a definer function returning just
-- (id, username) — no browse/search surface, so the user table can't be
-- enumerated. This is the entire discovery API.
create or replace function public.lookup_username(p_username text)
returns table (id uuid, username text)
language sql
security definer
stable
set search_path = public
as $$
  select id, username
  from profiles
  where lower(username) = lower(p_username)
  limit 1;
$$;

revoke all on function public.lookup_username(text) from public, anon;
grant execute on function public.lookup_username(text) to authenticated;

-- One canonical row per pair; requester records who asked.
create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references public.profiles (id) on delete cascade,
  addressee uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (requester <> addressee)
);

-- Prevents both A→B and B→A rows existing at once.
create unique index friendships_pair_idx
  on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index friendships_requester_idx on public.friendships (requester, status);
create index friendships_addressee_idx on public.friendships (addressee, status);

alter table public.friendships enable row level security;

create policy "own friendships" on public.friendships
  for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

create policy "send request" on public.friendships
  for insert to authenticated
  with check (requester = auth.uid() and status = 'pending');

-- Only the addressee responds (accept); either side can delete
-- (cancel / decline / unfriend).
create policy "respond to request" on public.friendships
  for update to authenticated
  using (addressee = auth.uid())
  with check (addressee = auth.uid());

create policy "end friendship" on public.friendships
  for delete to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

-- The helper every sharing policy builds on. Definer so policies that call
-- it never recurse into friendships' own RLS.
create or replace function public.is_friend(p_other uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester = auth.uid() and addressee = p_other)
        or (requester = p_other and addressee = auth.uid()))
  );
$$;

revoke all on function public.is_friend(uuid) from public, anon;
grant execute on function public.is_friend(uuid) to authenticated;

-- Friends may read each other's profile row (username + sharing state) so
-- feed items and requests can be attributed. Still no browse surface.
create policy "friends read profiles" on public.profiles
  for select to authenticated
  using (is_friend(id));


-- ─────────────────────────────────────────────────────────────────────────
-- 0012_feed_sharing.sql
-- ─────────────────────────────────────────────────────────────────────────
-- The feed. Privacy model: NOTHING reaches the feed implicitly. Feed items
-- exist only for deliberate publish acts:
--   1. recommending a save        -> feed_events kind 'recommended_save'
--   2. making a list friends-visible -> feed_events kind 'shared_list'
--   3. reviews (already community content) are attributed to friends
-- Saves stay private unless referenced by one of those acts; personal notes
-- move to a per-user table so they NEVER cross the boundary.

-- Publish state -------------------------------------------------------------

alter table public.profiles
  add column sharing_paused boolean not null default false;

alter table public.lists
  add column visibility text not null default 'private'
    check (visibility in ('private', 'friends'));

create table public.feed_events (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('recommended_save', 'shared_list')),
  save_id uuid references public.saves (id) on delete cascade,
  list_id uuid references public.lists (id) on delete cascade,
  created_at timestamptz not null default now(),
  check ((kind = 'recommended_save') = (save_id is not null)),
  check ((kind = 'shared_list') = (list_id is not null))
);

create unique index feed_events_save_unique
  on public.feed_events (actor_id, save_id) where save_id is not null;
create unique index feed_events_list_unique
  on public.feed_events (actor_id, list_id) where list_id is not null;
create index feed_events_actor_created_idx
  on public.feed_events (actor_id, created_at desc);
create index feed_events_save_idx on public.feed_events (save_id) where save_id is not null;

-- Personal notes move off saves so a recommended/shared save never exposes
-- them. Bonus: each user can keep their own note on any save they can read.
create table public.save_notes (
  save_id uuid not null references public.saves (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  note text not null,
  updated_at timestamptz not null default now(),
  primary key (save_id, user_id)
);

insert into public.save_notes (save_id, user_id, note)
select id, user_id, note from public.saves where note is not null;

alter table public.saves drop column note;

-- Visibility helpers (security definer: no policy recursion) ----------------

create or replace function public.is_sharing_paused(p_user uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select coalesce((select sharing_paused from profiles where id = p_user), false);
$$;

create or replace function public.save_visible_to_me(p_save uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists (
    select 1 from feed_events fe
    where fe.save_id = p_save
      and fe.kind = 'recommended_save'
      and public.is_friend(fe.actor_id)
      and not public.is_sharing_paused(fe.actor_id)
  ) or exists (
    select 1
    from list_items li
    join lists l on l.id = li.list_id
    where li.save_id = p_save
      and l.visibility = 'friends'
      and public.is_friend(l.user_id)
      and not public.is_sharing_paused(l.user_id)
  );
$$;

create or replace function public.can_read_save(p_save uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists (select 1 from saves where id = p_save and user_id = auth.uid())
      or public.save_visible_to_me(p_save);
$$;

create or replace function public.can_read_list(p_list uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists (
    select 1 from lists
    where id = p_list
      and (user_id = auth.uid()
        or (visibility = 'friends'
            and public.is_friend(user_id)
            and not public.is_sharing_paused(user_id)))
  );
$$;

revoke all on function public.is_sharing_paused(uuid) from public, anon;
revoke all on function public.save_visible_to_me(uuid) from public, anon;
revoke all on function public.can_read_save(uuid) from public, anon;
revoke all on function public.can_read_list(uuid) from public, anon;
grant execute on function public.is_sharing_paused(uuid) to authenticated;
grant execute on function public.save_visible_to_me(uuid) to authenticated;
grant execute on function public.can_read_save(uuid) to authenticated;
grant execute on function public.can_read_list(uuid) to authenticated;

-- Policy rewrite: reads follow visibility, writes stay owner-only ------------

drop policy "own saves" on public.saves;
create policy "saves readable" on public.saves
  for select to authenticated
  using (user_id = auth.uid() or save_visible_to_me(id));
create policy "saves insert" on public.saves
  for insert to authenticated with check (user_id = auth.uid());
create policy "saves update" on public.saves
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "saves delete" on public.saves
  for delete to authenticated using (user_id = auth.uid());

drop policy "own save places" on public.save_places;
create policy "save places readable" on public.save_places
  for select to authenticated using (can_read_save(save_id));
create policy "save places writable" on public.save_places
  for insert to authenticated
  with check (exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid()));
create policy "save places deletable" on public.save_places
  for delete to authenticated
  using (exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid()));

drop policy "own save links" on public.save_links;
create policy "save links readable" on public.save_links
  for select to authenticated using (can_read_save(save_id));
create policy "save links writable" on public.save_links
  for insert to authenticated
  with check (exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid()));
create policy "save links deletable" on public.save_links
  for delete to authenticated
  using (exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid()));

drop policy "own lists" on public.lists;
create policy "lists readable" on public.lists
  for select to authenticated using (can_read_list(id));
create policy "lists insert" on public.lists
  for insert to authenticated with check (user_id = auth.uid());
create policy "lists update" on public.lists
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "lists delete" on public.lists
  for delete to authenticated using (user_id = auth.uid());

drop policy "own list items" on public.list_items;
create policy "list items readable" on public.list_items
  for select to authenticated using (can_read_list(list_id));
create policy "list items writable" on public.list_items
  for insert to authenticated
  with check (exists (select 1 from public.lists l where l.id = list_id and l.user_id = auth.uid()));
create policy "list items deletable" on public.list_items
  for delete to authenticated
  using (exists (select 1 from public.lists l where l.id = list_id and l.user_id = auth.uid()));

alter table public.feed_events enable row level security;

create policy "feed readable" on public.feed_events
  for select to authenticated
  using (
    actor_id = auth.uid()
    or (is_friend(actor_id) and not is_sharing_paused(actor_id))
  );

create policy "publish own events" on public.feed_events
  for insert to authenticated
  with check (
    actor_id = auth.uid()
    and (save_id is null or exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid()))
    and (list_id is null or exists (select 1 from public.lists l where l.id = list_id and l.user_id = auth.uid()))
  );

create policy "retract own events" on public.feed_events
  for delete to authenticated using (actor_id = auth.uid());

alter table public.save_notes enable row level security;

create policy "own notes" on public.save_notes
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ─────────────────────────────────────────────────────────────────────────
-- 0013_pending_profile_visibility.sql
-- ─────────────────────────────────────────────────────────────────────────
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


-- ─────────────────────────────────────────────────────────────────────────
-- 0014_membership.sql
-- ─────────────────────────────────────────────────────────────────────────
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


-- ─────────────────────────────────────────────────────────────────────────
-- 0015_trip_photos.sql
-- ─────────────────────────────────────────────────────────────────────────
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


-- ─────────────────────────────────────────────────────────────────────────
-- 0016_events.sql
-- ─────────────────────────────────────────────────────────────────────────
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


