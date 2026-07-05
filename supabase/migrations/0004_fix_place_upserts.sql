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
