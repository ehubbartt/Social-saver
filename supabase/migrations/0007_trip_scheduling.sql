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
