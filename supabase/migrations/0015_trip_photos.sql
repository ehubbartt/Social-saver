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
