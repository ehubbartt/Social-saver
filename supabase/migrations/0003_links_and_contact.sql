-- Contact info on places, found via web search during ingest.
alter table public.places
  add column website text,
  add column phone text;

-- Non-place links mentioned in a video: app recommendations, products,
-- booking pages, official sites.
create table public.save_links (
  id uuid primary key default gen_random_uuid(),
  save_id uuid not null references public.saves (id) on delete cascade,
  title text not null,
  url text not null,
  kind text not null default 'website',
  note text,
  created_at timestamptz not null default now()
);

create index save_links_save_idx on public.save_links (save_id);

alter table public.save_links enable row level security;

create policy "own save links" on public.save_links
  for all using (
    exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.saves s where s.id = save_id and s.user_id = auth.uid())
  );
