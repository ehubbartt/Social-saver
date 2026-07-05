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
