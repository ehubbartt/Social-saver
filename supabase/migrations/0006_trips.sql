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
