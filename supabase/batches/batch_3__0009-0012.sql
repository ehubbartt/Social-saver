-- Run this AFTER the previous batch. Paste into Supabase SQL editor and Run.

-- ===== 0009_place_discovery.sql =====
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


-- ===== 0010_place_reviews.sql =====
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


-- ===== 0011_friends.sql =====
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


-- ===== 0012_feed_sharing.sql =====
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


