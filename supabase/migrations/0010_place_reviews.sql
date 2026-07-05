-- Place reviews: star rating + a "worth it?" verdict + an optional written
-- take. One review per user per place, editable. Unlike saves (private),
-- reviews are community content by design: any signed-in user can read them;
-- no display identity is attached (the app shows "You" only on your own).

create table public.place_reviews (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  worth_it boolean not null,
  body text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (place_id, user_id)
);

create index place_reviews_place_idx on public.place_reviews (place_id, created_at desc);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger place_reviews_touch
  before update on public.place_reviews
  for each row execute function public.touch_updated_at();

alter table public.place_reviews enable row level security;

create policy "reviews are readable" on public.place_reviews
  for select to authenticated using (true);

create policy "insert own review" on public.place_reviews
  for insert to authenticated with check (user_id = auth.uid());

create policy "update own review" on public.place_reviews
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "delete own review" on public.place_reviews
  for delete to authenticated using (user_id = auth.uid());
