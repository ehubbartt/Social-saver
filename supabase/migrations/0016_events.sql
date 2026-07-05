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
