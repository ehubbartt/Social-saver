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
