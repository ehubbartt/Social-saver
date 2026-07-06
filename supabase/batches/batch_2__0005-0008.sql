-- Run this AFTER the previous batch. Paste into Supabase SQL editor and Run.

-- ===== 0005_add_note.sql =====
-- Personal note on a save (e.g. "Mia recommended this", "book ahead").
alter table public.saves add column note text;


-- ===== 0006_trips.sql =====
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


-- ===== 0007_trip_scheduling.sql =====
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


-- ===== 0008_trip_item_constraints.sql =====
-- Database-level backstop for the trip agent and app clients: whatever a
-- caller manages to send, trip items stay structurally coherent.
alter table public.trip_items
  add constraint trip_items_kind_check
    check (kind in ('save', 'flight', 'hotel', 'transport', 'custom')),
  add constraint trip_items_save_presence
    check ((kind = 'save') = (save_id is not null)),
  add constraint trip_items_day_range
    check (day_index is null or (day_index >= 1 and day_index <= 31));


