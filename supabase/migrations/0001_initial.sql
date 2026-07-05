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
